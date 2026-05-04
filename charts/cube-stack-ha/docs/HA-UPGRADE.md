# HA cluster — operations runbook

This runbook covers **routine operations** against a healthy
`cube-stack-ha` release: rolling restarts, drains, and image bumps.
It assumes `make ha-verify` was green before you started.

For chart-version migrations (e.g. moving from `cube-stack@1.0.0`
with the HA toggle to `cube-stack-ha@1.0.0`), see
[UPGRADE.md](../UPGRADE.md) instead — that's a fresh-install path.

---

## 1. Pre-flight checks

Always run these **before** any maintenance window.

### 1.1 Quorum math

3 routers → tolerates 1 down. 5 routers → tolerates 2 down. **Never**
plan a maintenance that takes more than `floor(N/2)` routers offline
at the same time. The chart's PDB (`minAvailable=replicas-1`) will
block voluntary disruptions that violate this, but `--force` and
`--grace-period=0 --ignore-daemonsets` can bypass it — don't.

### 1.2 Cluster health snapshot

Port-forward each router's statsd-exporter sidecar (port `9102`) and
verify:

```bash
NS=cube-ha
for pod in $(kubectl -n $NS get pods -l app.kubernetes.io/component=cubestore-router -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n $NS port-forward $pod 9102:9102 >/dev/null 2>&1 &
  sleep 1
  echo "--- $pod ---"
  curl -s localhost:9102/metrics | grep -E '^cs_raft_(is_leader|term|leader_id)' || echo "(no raft metrics)"
  pkill -f "port-forward $pod" 2>/dev/null
  sleep 0.5
done
```

You want, across all 3 routers:

- Exactly **one** with `cs_raft_is_leader 1`. The other two with `0`.
- All three reporting the **same** `cs_raft_term`.
- All three reporting the **same** `cs_raft_leader_id`.
- Term must be **stable** for at least 30 seconds (run the loop twice,
  30s apart, and confirm the term didn't move).

If term is moving fast, you're in an election — wait it out before
draining.

### 1.3 PVC capacity

Routers crash-loop if their PVC fills (RocksDB metastore + Raft log
share the disk). Run:

```bash
kubectl -n $NS exec -ti <router-0> -- du -sh /cube/.cubestore/data/* 2>/dev/null
kubectl -n $NS get pvc -l app.kubernetes.io/component=cubestore-router
```

If any PVC is over 70% full, plan a resize (or remote-storage cleanup)
first; see TROUBLESHOOTING.md.

---

## 2. Drain protocol (one node down for maintenance)

```
1. Identify the leader pod (via cs_raft_is_leader=1 in 1.2).
2. Identify which node hosts the leader.
3. Drain a non-leader node first.
4. Wait for the surviving 2 routers to report stable term + leader.
5. If that drained node hosted a router, wait for the router pod to
   reschedule onto another node and rejoin Raft (term should NOT move
   when a follower comes back — only when a leader changes).
6. Repeat for the next non-leader-hosting node, if any.
7. Drain the leader-hosting node LAST. Election triggers; new leader
   emerges within budget (M8 tested 6-10s).
8. Run `make ha-verify` once everything is back.
```

Why leader last: every time the leader goes away you incur an
election (~5-10s of write unavailability per Raft term change).
Doing it once instead of three times keeps client-visible disruption
minimal.

---

## 3. Rolling restart (image bump, env change)

**Don't** use `kubectl rollout restart sts/...` — the StatefulSet uses
`podManagementPolicy: Parallel` (needed at first-install for Raft
bootstrap), so a rollout restart kills all 3 pods at once and the
cluster has to bootstrap from cold. That's a >30s outage and you'll
trip B1's `CubeStoreNoLeader` alert.

Use the per-pod loop instead:

```bash
NS=cube-ha
STS=$(kubectl -n $NS get sts -l app.kubernetes.io/component=cubestore-router -o name)
REPLICAS=$(kubectl -n $NS get $STS -o jsonpath='{.spec.replicas}')

# pick the pod ordering: non-leaders first, leader last
LEADER=$(/path/to/leader-detector.sh)   # see 1.2
for ord in $(seq 0 $(($REPLICAS - 1))); do
  POD="${STS#statefulset.apps/}-$ord"
  if [ "$POD" = "$LEADER" ]; then continue; fi
  echo "==> deleting $POD"
  kubectl -n $NS delete pod $POD
  kubectl -n $NS wait --for=condition=ready pod/$POD --timeout=120s
  # wait 5s for raft to settle before next pod
  sleep 5
done

# leader last
echo "==> deleting leader $LEADER"
kubectl -n $NS delete pod $LEADER
kubectl -n $NS wait --for=condition=ready pod/$LEADER --timeout=120s
```

Each pod gets its replacement created automatically by the
StatefulSet controller, picks up the new image on PullPolicy: Always
(or already-cached on IfNotPresent), reads its NODE_ID from the pod
ordinal, and rejoins the Raft cluster as a follower (or, if it was the
leader, triggers a single election).

---

## 4. Backup before risky changes

Always snapshot the leader's PVC before:

- A chart upgrade that touches `router.persistence.size` (resize
  in-place is sometimes unsupported).
- A migration from one remote-storage backend to another.
- Any procedure that calls `make ha-reset` (it deletes all PVCs).

The B2 backup CronJob (rolled out in PR-5) automates this. Manual
snapshot via your cloud provider's volume snapshot API is the
fallback.

Restore: see [RESTORE.md](../../../docs/RESTORE.md) (added in PR-5).

---

## 5. Failure modes (and what they look like)

| Symptom | Likely cause | Recovery |
|---|---|---|
| `CubeStoreNoLeader` firing for >2m | All routers down OR network partition | check `kubectl -n $NS get pods`; if all 3 are NotReady, see TROUBLESHOOTING `raft cluster won't elect leader` |
| `CubeStoreRaftLeaderFlapping` | TCP transport churning on cached connections after pod IPs recycle (M8 fix in agriev/cube addresses this) | confirm fork image ≥ M8 commit `7903c33`; rolling restart |
| `CubeStoreRaftTermAdvancingFast` (election storm) | leader is CPU-saturated OR network instability | check resources on leader pod; check pod-to-pod connectivity over the headless service (port 9100) |
| One router stuck NotReady but others healthy | bad PVC (DiskPressure, full, corrupt) | `kubectl describe pvc` on the failed pod's PVC; if disk-pressure, see `make ha-deploy`'s pre-flight |
| `ImagePullBackOff` after upgrade | fork image not pushed / wrong arch | verify `cubestoreImage.repository` + `tag`; for ARM64 nodes check that you built/pushed the arm64v8 variant |

---

## 6. When to reach for `make ha-reset`

`make ha-reset` is the **destructive** recovery path: it uninstalls the
release, drops all router PVCs, and re-installs from scratch. Raft
state and metastore are gone.

Only use it if:

- The cluster has lost quorum and you've confirmed via the
  TROUBLESHOOTING runbook that there's no recovery without data loss.
- You've **backed up the metastore** somewhere (B2 CronJob output,
  cloud volume snapshot, or a manual `kubectl exec`-tar dump).
- Downtime is acceptable.

After `ha-reset`, restore the metastore from your backup before
flipping `replicas` from 1 back up to 3 — see RESTORE.md.

---

## 7. Quick reference

```bash
# Health
make ha-verify                         # election + single-failover smoke
kubectl -n cube-ha get pods,pvc,svc

# Drain protocol
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data \
  --grace-period=60                    # PDB enforces quorum

# Rolling restart
# (use the per-pod loop in section 3, NOT kubectl rollout restart)

# Force an election (for testing)
kubectl -n cube-ha delete pod <leader>

# Last resort
make ha-reset                          # destructive — read section 6 first
```
