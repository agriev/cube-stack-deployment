# cube-stack-ha — troubleshooting

HA-specific issues only. For problems that exist in vanilla
`cube-stack` too (image pulls, datasource validation, refresh-worker
OOM, GCS/S3 creds, ingress, schema), see
[../../cube-stack/docs/TROUBLESHOOTING.md](../../cube-stack/docs/TROUBLESHOOTING.md).

For routine ops on a healthy HA cluster, see the runbook at
[HA-UPGRADE.md](HA-UPGRADE.md).

---

## Raft cluster won't elect a leader

**Symptom.** All 3 routers Ready but `cs_raft_is_leader` is `0` on
every pod for >1 minute. `CubeStoreNoLeader` PrometheusRule alert
fires.

**Diagnostic.**

```bash
NS=cube-ha
# 1. Confirm headless service has 3 endpoints
HEADLESS=$(kubectl -n $NS get svc -l app.kubernetes.io/component=cubestore-router \
  -o jsonpath='{.items[?(@.spec.clusterIP=="None")].metadata.name}')
kubectl -n $NS describe endpoints "$HEADLESS"   # should list 3 IPs

# 2. Sample raft term across all pods (look for matching values)
for pod in $(kubectl -n $NS get pods -l app.kubernetes.io/component=cubestore-router \
    -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n $NS port-forward $pod 9102:9102 >/dev/null 2>&1 &
  sleep 1
  echo "--- $pod ---"
  curl -s localhost:9102/metrics | grep -E '^cs_raft_(term|is_leader|leader_id)' || echo "(no metrics)"
  pkill -f "port-forward $pod" 2>/dev/null
  sleep 0.5
done

# 3. Check CUBESTORE_RAFT_PEERS is consistent across pods
for pod in $(kubectl -n $NS get pods -l app.kubernetes.io/component=cubestore-router \
    -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $pod ---"
  kubectl -n $NS exec $pod -- env | grep RAFT
done

# 4. Pod-to-pod DNS resolution (run from any router pod)
kubectl -n $NS exec <router-0> -- nslookup <router-1>.<headless>
```

**Causes & fixes.**

- **Headless service has fewer than 3 endpoints.** A pod is
  `Pending` or `NotReady`. Check `kubectl get pods` and the failing
  pod's events. Most common: PVC stuck `Pending` (storage class
  doesn't exist), or DiskPressure on the node (see disk-pressure
  pre-flight in `make ha-deploy`).

- **`CUBESTORE_RAFT_PEERS` differs between pods.** Should never
  happen — the helm helper renders the same string on every pod. If
  you see this, you've patched the StatefulSet by hand. Re-`helm
  upgrade` to restore the rendered config.

- **Pod-to-pod DNS times out.** A NetworkPolicy is blocking inter-
  pod traffic on the raft port (default 9100). Either disable the
  policy temporarily (`kubectl delete networkpolicy ...`) or add a
  rule allowing intra-namespace traffic on tcp/9100.

- **Term advancing fast (election storm).** See next section.

---

## Election storm — `CubeStoreRaftTermAdvancingFast` alert

**Symptom.** Term increments faster than 1 election / 10s.
`cs_raft_term` keeps going up, never stabilizes; queries return
"no leader" with a `raft-leader-id=N` hint.

**Causes & fixes.**

- **TCP transport churning on cached connections after pod IP
  recycling.** This is the M8 bug in agriev/cube — fixed in commit
  `7903c33` (`fix(cubestore/raft): TCP transport — fresh connect per
  send`). Make sure your `cubestoreImage.tag` is built from
  `ha-main` ≥ M8-complete.

- **Leader pod is CPU-saturated.** Heartbeats time out, followers
  start elections, leader recovers, repeat. Check
  `kubectl top pods -n cube-ha`. Bump
  `cubestore.router.resources.limits.cpu` if leader is sitting at the
  CPU limit during normal operation.

- **Cross-AZ network latency.** If your routers span zones with
  >50ms round-trip, the default raft heartbeat interval is too
  aggressive. The fork's heartbeat is 100ms; bumping it requires a
  rebuild of the fork's binary.

- **Settle window too short between chaos cycles.** If you're
  running `ha-chaos.sh` with `SETTLE_BETWEEN=0`, the cluster never
  fully heals between rounds. Use the default (30s) or longer. The
  multi-cycle test in `ha-soak.sh` paces itself with `INTERVAL=120s`.

---

## PVC stuck `Pending` after `make ha-reset`

**Symptom.** After `make ha-reset` the new pods sit in `Pending` for
minutes; `kubectl describe pod` says
`pod has unbound immediate PersistentVolumeClaims`.

**Cause.** rancher's local-path-provisioner (used by docker-desktop's
default storage class on `make ha-deploy`) is slow to provision
hostpath PVs after a quick delete-recreate.

**Fix.** Wait. PVC provisioning typically completes within 60s.
`watch kubectl get pvc -n cube-ha`. If a PVC is still
`Pending` after 2 minutes, check the provisioner logs:

```bash
kubectl -n local-path-storage logs -l app=local-path-provisioner
```

If you see `failed to create pv` errors about disk space, the
docker-desktop VM's disk image has filled up. `kubectl describe node
docker-desktop | grep DiskPressure`. Free disk via Docker Desktop
Settings → Resources → Disk image size.

---

## Multi-cycle chaos cascades into election storm

**Symptom.** `make ha-chaos` round 1 passes; round 2 takes 60+
seconds; round 3 fails with "no NEW leader within budget".

**Cause.** Repeated kills before the cluster has fully healed leave
stale TCP streams in the surviving pods' transport layer; restarted
pods get new IPs that the cached streams don't know about.

**Fix.** Two complementary actions:

- **Increase `SETTLE_BETWEEN`** in `make ha-chaos` (default 30s; bump
  to 60s if you see this on slower clusters):

  ```bash
  SETTLE_BETWEEN=60 make ha-chaos
  ```

- **Confirm the M8 transport fix is in your image.** The fix
  (`fresh-connect-per-send`) lands in fork commit `7903c33`. The
  `cubestore-ha:vdev` tag built by `make ha-image` from
  `agriev/cube@ha-main` includes it. If you've pinned an older tag,
  rebuild.

---

## Leader hint marker — `raft-leader-id=N` in errors

**Symptom.** Cube API errors show
`error: cubestore: not the leader (raft-leader-id=2)`.

**This is by design.** The agriev/cube fork's M6.2 work added a
"leader hint" marker so out-of-loop callers (Cube API, cube-store-sql
clients) know which pod *is* the leader and can retry against it.
Your retry logic should:

1. Parse the `raft-leader-id=N` value.
2. Resolve `<rel>-cubestore-router-(N-1)` (raft id 1 = pod-0).
3. Retry the request against that pod.

The Cube API's own retry logic does this automatically; if you see
this error reaching the user, look for a stale connection on the API
side that's pinned to a non-leader.

---

## See also

- [Routine ops runbook (HA-UPGRADE.md)](HA-UPGRADE.md) — drains,
  rolling restarts, backups.
- [Vanilla shared issues (TROUBLESHOOTING.md)](../../cube-stack/docs/TROUBLESHOOTING.md) —
  ImagePullBackOff, datasource validation, refresh-worker OOM, etc.
- [agriev/cube HA roadmap](https://github.com/agriev/cube/blob/ha-main/HA.md) —
  upstream HA work + status.
