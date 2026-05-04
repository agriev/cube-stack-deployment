#!/usr/bin/env bash
#
# ha-soak.sh — long-running soak test for the HA Raft cluster.
#
# Runs an interleaved chaos loop for $DURATION (default 1h):
#   - kill-leader        (40% probability)
#   - kill-follower      (30% probability)
#   - rolling-restart    (20% probability — delete a random non-leader, wait Ready)
#   - just observe       (10% probability — no action, useful for sampling stable terms)
#
# Records every leader transition (pod name, term jump, failover ms)
# to a jsonl file at $OUT (default /tmp/ha-soak-<timestamp>.jsonl) so
# the result can be ingested into Grafana / Loki for trend analysis.
#
# Exits non-zero on any failover that takes longer than $FAILOVER_BUDGET
# (default 30s) so a nightly CI run can fail loudly on regressions.
#
# Defaults — override via env:
#   NS=cube-ha
#   DURATION=3600                      seconds; pass 600 for a 10-min smoke run
#   INTERVAL=120                       seconds between actions
#   FAILOVER_BUDGET=30                 seconds; alert on any slower failover
#   OUT=/tmp/ha-soak-<ts>.jsonl
#
# Cycle output (one line per action, jsonl):
#   {"ts":"...", "round":N, "action":"kill-leader", "leader_before":"...",
#    "leader_after":"...", "term_before":N, "term_after":N, "failover_secs":N}

set -euo pipefail

NS=${NS:-cube-ha}
DURATION=${DURATION:-3600}
INTERVAL=${INTERVAL:-120}
FAILOVER_BUDGET=${FAILOVER_BUDGET:-30}
ROUTER_LABEL="app.kubernetes.io/component=cubestore-router"
METRICS_PORT=${METRICS_PORT:-9102}
METRICS_PATH=${METRICS_PATH:-/metrics}
LOCAL_PORT_BASE=${LOCAL_PORT_BASE:-33000}
OUT=${OUT:-/tmp/ha-soak-$(date -u +%Y%m%dT%H%M%S).jsonl}

# Sample $cs_raft_is_leader and $cs_raft_term from one pod via port-forward.
# Output: "<is_leader> <term>" or empty string if metrics unavailable.
sample_pod() {
  local pod="$1" idx="$2" pf_pid local_port out
  local_port=$((LOCAL_PORT_BASE + idx))
  kubectl -n "$NS" port-forward "$pod" "${local_port}:${METRICS_PORT}" \
    >/dev/null 2>&1 &
  pf_pid=$!
  sleep 0.4
  out=$(curl -sf "http://localhost:${local_port}${METRICS_PATH}" 2>/dev/null \
    | awk '/^cs_raft_is_leader/ {is=$2} /^cs_raft_term/ {term=$2} END {if (is != "") print is, term}')
  kill "$pf_pid" 2>/dev/null
  wait "$pf_pid" 2>/dev/null || true
  echo "$out"
}

# Returns "leader_pod term" of the current leader (or empty leader_pod if none).
cluster_state() {
  local i=0 pod is_l term leader=""
  local max_term=0
  for pod in $(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}'); do
    local snap
    snap=$(sample_pod "$pod" "$i") || true
    if [ -n "$snap" ]; then
      is_l=$(echo "$snap" | awk '{print $1}')
      term=$(echo "$snap" | awk '{print $2}')
      if [ "${term:-0}" -gt "$max_term" ]; then max_term=$term; fi
      if [ "$is_l" = "1" ]; then leader=$pod; fi
    fi
    i=$((i + 1))
  done
  echo "$leader $max_term"
}

# Pick action based on weighted RNG.
pick_action() {
  local r=$((RANDOM % 100))
  if   [ "$r" -lt 40 ]; then echo "kill-leader"
  elif [ "$r" -lt 70 ]; then echo "kill-follower"
  elif [ "$r" -lt 90 ]; then echo "rolling-restart"
  else                       echo "observe"
  fi
}

random_follower() {
  local leader="$1"
  local pods=()
  for pod in $(kubectl -n "$NS" get pods -l "$ROUTER_LABEL" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{end}'); do
    [ "$pod" != "$leader" ] && pods+=("$pod")
  done
  [ ${#pods[@]} -eq 0 ] && { echo ""; return; }
  echo "${pods[$((RANDOM % ${#pods[@]}))]}"
}

emit() {
  local round=$1 action=$2 lb=$3 la=$4 tb=$5 ta=$6 fs=$7
  printf '{"ts":"%s","round":%d,"action":"%s","leader_before":"%s","leader_after":"%s","term_before":%d,"term_after":%d,"failover_secs":%d}\n' \
    "$(date -u +%FT%TZ)" "$round" "$action" "$lb" "$la" "$tb" "$ta" "$fs" >> "$OUT"
}

echo "==> ha-soak: NS=$NS DURATION=${DURATION}s INTERVAL=${INTERVAL}s OUT=$OUT"
echo "    failover budget per cycle: ${FAILOVER_BUDGET}s"

end_at=$(($(date +%s) + DURATION))
round=0
fail_count=0

while [ "$(date +%s)" -lt "$end_at" ]; do
  round=$((round + 1))
  action=$(pick_action)

  read -r leader_before term_before <<<"$(cluster_state)"
  : "${leader_before:=}"
  : "${term_before:=0}"

  echo "--- round $round  action=$action  leader_before=${leader_before:-NONE}  term=$term_before"

  case "$action" in
    kill-leader)
      [ -z "$leader_before" ] && { echo "  (no leader; skipping)"; emit "$round" "$action" "" "" 0 0 0; sleep "$INTERVAL"; continue; }
      kill_at=$(date +%s)
      kubectl -n "$NS" delete pod "$leader_before" --force --grace-period=0 >/dev/null 2>&1 || true
      ;;
    kill-follower)
      victim=$(random_follower "$leader_before")
      [ -z "$victim" ] && { echo "  (no follower; skipping)"; emit "$round" "$action" "$leader_before" "$leader_before" "$term_before" "$term_before" 0; sleep "$INTERVAL"; continue; }
      kill_at=$(date +%s)
      kubectl -n "$NS" delete pod "$victim" --force --grace-period=0 >/dev/null 2>&1 || true
      ;;
    rolling-restart)
      victim=$(random_follower "$leader_before")
      [ -z "$victim" ] && { echo "  (no follower; skipping)"; sleep "$INTERVAL"; continue; }
      kill_at=$(date +%s)
      kubectl -n "$NS" delete pod "$victim" >/dev/null 2>&1 || true
      kubectl -n "$NS" wait --for=condition=ready pod/"$victim" --timeout=120s >/dev/null 2>&1 || true
      ;;
    observe)
      emit "$round" "$action" "$leader_before" "$leader_before" "$term_before" "$term_before" 0
      sleep "$INTERVAL"
      continue
      ;;
  esac

  # Wait for the cluster to recover (one leader, term stable).
  deadline=$((kill_at + FAILOVER_BUDGET))
  leader_after=""
  term_after=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    read -r la ta <<<"$(cluster_state)"
    if [ -n "$la" ]; then
      leader_after=$la
      term_after=$ta
      break
    fi
    sleep 1
  done
  failover_secs=$(($(date +%s) - kill_at))

  if [ -z "$leader_after" ]; then
    echo "  FAIL: no leader within ${FAILOVER_BUDGET}s"
    fail_count=$((fail_count + 1))
    leader_after=""
    term_after=$term_before
  else
    echo "  recovered: leader=$leader_after term=$term_after failover=${failover_secs}s"
  fi
  emit "$round" "$action" "$leader_before" "$leader_after" "$term_before" "$term_after" "$failover_secs"

  sleep "$INTERVAL"
done

total=$(date -u +%FT%TZ)
echo
echo "==> Soak complete: $round rounds, $fail_count failures over the budget (${FAILOVER_BUDGET}s)"
echo "==> Output:        $OUT"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
