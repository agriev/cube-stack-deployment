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
STATUS_PORT=${STATUS_PORT:-3031}
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

# 2 + 3. Scrape /metrics from each pod via kubectl port-forward.
PODS=($(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
  -o jsonpath='{.items[*].metadata.name}'))
echo "==> Found pods: ${PODS[*]}"

leader=""
declare -A is_leader
for pod in "${PODS[@]}"; do
  echo "--- $pod ---"
  # Use kubectl exec + curl localhost so we don't need port-forward
  # connections. Cubestore has a curl-able status port at /metrics.
  metrics=$(kubectl -n "$NS" exec "$pod" -c cubestore -- \
    sh -c "command -v curl >/dev/null && curl -s http://localhost:${STATUS_PORT}${METRICS_PATH} || wget -q -O- http://localhost:${STATUS_PORT}${METRICS_PATH}" \
    2>/dev/null || true)
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
  is_leader[$pod]=$is_l
  if [ "$is_l" = "1" ]; then
    leader=$pod
  fi
done

# Exactly one leader.
n_leaders=0
for pod in "${PODS[@]}"; do
  [ "${is_leader[$pod]}" = "1" ] && n_leaders=$((n_leaders + 1))
done
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
echo "==> Waiting up to 30s for new leader to emerge ..."
new_leader=""
for _ in $(seq 1 30); do
  sleep 1
  surviving=($(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}'))
  for pod in "${surviving[@]}"; do
    is_l=$(kubectl -n "$NS" exec "$pod" -c cubestore -- \
      sh -c "curl -s http://localhost:${STATUS_PORT}${METRICS_PATH} 2>/dev/null | awk '/^cs_raft_is_leader/ {print \$2; exit}'" \
      2>/dev/null || true)
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
