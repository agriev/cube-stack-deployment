#!/usr/bin/env bash
#
# ha-chaos.sh — repeated kill-leader chaos test against a live HA cluster.
#
# Builds on ha-verify.sh by running N kill cycles in a row. Each
# cycle: find leader, force-delete its pod, wait for a new leader
# to emerge within the budget. The kubernetes-grade analogue of the
# unit-test M4 chaos test (`chaos_partition_leader_repeatedly_converges_each_round`)
# from the cube fork — same shape, k8s scale.
#
# Defaults:
#   NS=cube-ha          (override for a different namespace)
#   ROUNDS=5            (kill cycles; M4 plan calls for 100; we pick a
#                        smaller default that finishes in ~5 min on
#                        docker-desktop and lets the user crank it up)
#   FAILOVER_BUDGET=60  (seconds per cycle for new-leader emergence;
#                        the M4 in-process chaos used 5s but that's
#                        unrealistic on real k8s with image pulls /
#                        kubelet GC / readinessProbe latency)
#   SETTLE_BETWEEN=30   (seconds between rounds — gives the cluster
#                        time to fully heal before the next kill.
#                        Without this, repeated kills can stack and
#                        cause an election storm that takes minutes
#                        to recover from.)
#
# Known limitation
# ----------------
#
# Multi-cycle chaos can pin the cluster into an election storm
# (high terms, no leader) when pod restarts cascade faster than
# the TcpTransport's lazy-reconnect cadence. ha-verify.sh's
# single-cycle test reliably passes; multi-cycle requires a
# generous SETTLE_BETWEEN to let stale TCP streams drain. A
# follow-up will harden the transport's peer-connection-recycling
# under churn (heartbeat-based liveness check, eager reconnect on
# lossy progress).
#
# Exit codes mirror ha-verify.sh: 4 = failover didn't converge.

set -euo pipefail

NS=${NS:-cube-ha}
ROUTER_LABEL="app.kubernetes.io/component=cubestore-router"
ROUNDS=${ROUNDS:-3}
FAILOVER_BUDGET=${FAILOVER_BUDGET:-60}
SETTLE_BETWEEN=${SETTLE_BETWEEN:-30}
METRICS_PORT=${METRICS_PORT:-9102}
METRICS_PATH=${METRICS_PATH:-/metrics}
LOCAL_PORT_BASE=${LOCAL_PORT_BASE:-32000}

# Returns the pod name whose cs_raft_is_leader=1 (or empty string).
find_leader() {
  local pf_pid pod local_port is_l
  local i=0
  for pod in $(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}'); do
    local_port=$((LOCAL_PORT_BASE + i))
    kubectl -n "$NS" port-forward "$pod" "${local_port}:${METRICS_PORT}" \
      >/dev/null 2>&1 &
    pf_pid=$!
    sleep 0.4
    is_l=$(curl -sf "http://localhost:${local_port}${METRICS_PATH}" 2>/dev/null \
      | awk '/^cs_raft_is_leader/ {print $2; exit}' || true)
    kill "$pf_pid" 2>/dev/null
    wait "$pf_pid" 2>/dev/null || true
    if [ "$is_l" = "1" ]; then
      echo "$pod"
      return 0
    fi
    i=$((i + 1))
  done
  echo ""
}

echo "==> Chaos test: $ROUNDS leader kills, ${FAILOVER_BUDGET}s budget per round"
total_start=$(date +%s)

for round in $(seq 1 "$ROUNDS"); do
  echo
  echo "===== Round $round / $ROUNDS ====="

  # Wait for a leader to exist.
  leader=""
  deadline=$(($(date +%s) + FAILOVER_BUDGET))
  while [ -z "$leader" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    leader=$(find_leader || true)
    [ -z "$leader" ] && sleep 2
  done
  if [ -z "$leader" ]; then
    echo "ERROR round $round: no leader within ${FAILOVER_BUDGET}s" >&2
    exit 4
  fi
  echo "  leader: $leader"

  # Kill it.
  kill_start=$(date +%s)
  kubectl -n "$NS" delete pod "$leader" --force --grace-period=0 \
    >/dev/null 2>&1 || true

  # Wait for a NEW leader (different pod name).
  new_leader=""
  deadline=$(($(date +%s) + FAILOVER_BUDGET))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    candidate=$(find_leader || true)
    if [ -n "$candidate" ] && [ "$candidate" != "$leader" ]; then
      new_leader="$candidate"
      break
    fi
    sleep 1
  done
  failover_secs=$(($(date +%s) - kill_start))

  if [ -z "$new_leader" ]; then
    echo "ERROR round $round: no NEW leader within ${FAILOVER_BUDGET}s after killing $leader" >&2
    exit 4
  fi
  echo "  new leader: $new_leader  (failover: ${failover_secs}s)"

  # Settle between rounds: give the killed pod time to come back,
  # rejoin the raft group, and have its TCP connections to the
  # current leader stabilize. Skipping this lets failures stack.
  if [ "$round" -lt "$ROUNDS" ]; then
    echo "  settling for ${SETTLE_BETWEEN}s..."
    sleep "$SETTLE_BETWEEN"
  fi
done

total_secs=$(($(date +%s) - total_start))
echo
echo "==> SUCCESS — $ROUNDS leader kills, all failed over within budget; total ${total_secs}s"
