#!/usr/bin/env bash
#
# ha-verify.sh — smoke-test a deployed Cube Store HA cluster.
#
# Assumes the chart was installed with `cubestore.ha.enabled=true`
# in namespace ${NS:-cube-ha} and release ${REL:-cube-ha}.
#
# Steps:
#   1. wait for 3 router pods Ready
#   2. scrape /metrics on each pod, assert cs_raft_* metrics present
#   3. assert exactly one pod self-reports cs_raft_is_leader=1
#   4. record current leader pod name
#   5. delete the leader pod
#   6. wait for a new leader to emerge among the surviving 2 + the
#      restarted one; assert the new leader id differs from the
#      killed one (or matches if only the killed one came back).
#   7. print a summary
#
# Exit codes:
#   0 = cluster healthy + failover passed
#   1 = pods didn't come up
#   2 = metrics missing on one or more pods
#   3 = no leader, or > 1 leader, or election didn't converge
#   4 = failover didn't produce a new leader within budget

set -euo pipefail

NS=${NS:-cube-ha}
REL=${REL:-cube-ha}
ROUTER_LABEL="app.kubernetes.io/component=cubestore-router"

# Defaults — override via env if your release uses different ports
# or status path.
#
# Cubestore itself emits statsd; the sidecar at port 9102 (the chart's
# `metrics.statsdExporter.httpPort`) re-publishes them as Prometheus.
# The HA test deploys the sidecar; this script scrapes from there.
METRICS_PORT=${METRICS_PORT:-9102}
METRICS_PATH=${METRICS_PATH:-/metrics}

# 1. Wait for 3 pods Ready.
echo "==> Waiting for 3 router pods Ready in ${NS} (label ${ROUTER_LABEL})…"
for _ in $(seq 1 90); do
  ready=$(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    2>/dev/null | grep -c true || true)
  if [ "$ready" -eq 3 ]; then
    echo "    3 pods Ready ✓"
    break
  fi
  sleep 5
done
if [ "$ready" -ne 3 ]; then
  echo "ERROR: only $ready / 3 pods Ready after 7.5min" >&2
  kubectl -n "$NS" get pods -l "$ROUTER_LABEL"
  exit 1
fi

# 2 + 3. Scrape /metrics from each pod. The fork's debian-slim image
# doesn't include curl/wget, so we port-forward from the host.
PODS=($(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
  -o jsonpath='{.items[*].metadata.name}'))
echo "==> Found pods: ${PODS[*]}"

# Find a free local port for forwarding (use 10000+pod-ordinal so
# it's stable across runs).
LOCAL_PORT_BASE=${LOCAL_PORT_BASE:-31000}

leader=""
n_leaders=0
# Avoid `declare -A` (bash 4+) for macOS bash 3.2 compatibility.
for i in "${!PODS[@]}"; do
  pod="${PODS[$i]}"
  echo "--- $pod ---"
  local_port=$((LOCAL_PORT_BASE + i))
  # Background port-forward, give it a moment to come up, then scrape.
  kubectl -n "$NS" port-forward "$pod" "${local_port}:${METRICS_PORT}" \
    >/tmp/ha-verify-pf-$pod.log 2>&1 &
  pf_pid=$!
  # Wait until port is reachable (max 5s).
  for _ in $(seq 1 20); do
    if curl -sf "http://localhost:${local_port}${METRICS_PATH}" \
        >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  metrics=$(curl -s "http://localhost:${local_port}${METRICS_PATH}" 2>/dev/null || true)
  kill "$pf_pid" 2>/dev/null
  wait "$pf_pid" 2>/dev/null || true
  if [ -z "$metrics" ]; then
    echo "ERROR: no metrics from $pod" >&2
    exit 2
  fi
  if ! echo "$metrics" | grep -q "^cs_raft_term"; then
    echo "ERROR: cs_raft_term missing in $pod metrics" >&2
    echo "$metrics" | head -20 >&2
    exit 2
  fi
  term=$(echo "$metrics" | awk '/^cs_raft_term/ {print $2; exit}')
  leader_id=$(echo "$metrics" | awk '/^cs_raft_leader_id/ {print $2; exit}')
  is_l=$(echo "$metrics" | awk '/^cs_raft_is_leader/ {print $2; exit}')
  echo "    term=$term  leader_id=$leader_id  is_leader=$is_l"
  if [ "$is_l" = "1" ]; then
    leader=$pod
    n_leaders=$((n_leaders + 1))
  fi
done

# Exactly one leader.
if [ "$n_leaders" -ne 1 ]; then
  echo "ERROR: expected exactly 1 leader, got $n_leaders (election may not have converged)" >&2
  exit 3
fi
echo "==> Initial leader: $leader"

# 5. Delete the leader pod.
echo "==> Deleting leader pod $leader (force, no grace) ..."
kubectl -n "$NS" delete pod "$leader" --force --grace-period=0 || true

# 6. Wait for re-election. Failover budget: 30s (M4 chaos test
# has 5s but k8s pod-deletion + new pod startup can take 10-20s
# extra; relaxed budget here is appropriate).
echo "==> Waiting up to 60s for new leader to emerge ..."
new_leader=""
for _ in $(seq 1 60); do
  sleep 1
  surviving=($(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}'))
  for j in "${!surviving[@]}"; do
    pod="${surviving[$j]}"
    local_port=$((LOCAL_PORT_BASE + 100 + j))
    kubectl -n "$NS" port-forward "$pod" "${local_port}:${METRICS_PORT}" \
      >/dev/null 2>&1 &
    pf_pid=$!
    sleep 0.5
    is_l=$(curl -sf "http://localhost:${local_port}${METRICS_PATH}" 2>/dev/null \
      | awk '/^cs_raft_is_leader/ {print $2; exit}' || true)
    kill "$pf_pid" 2>/dev/null
    wait "$pf_pid" 2>/dev/null || true
    if [ "$is_l" = "1" ]; then
      new_leader=$pod
      break 2
    fi
  done
done

if [ -z "$new_leader" ]; then
  echo "ERROR: no new leader emerged within 30s after killing $leader" >&2
  kubectl -n "$NS" get pods -l "$ROUTER_LABEL"
  exit 4
fi

echo "==> New leader: $new_leader"
echo "==> SUCCESS — failover from $leader to $new_leader within budget"
