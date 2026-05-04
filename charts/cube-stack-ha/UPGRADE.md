# cube-stack-ha — upgrade guide

## First release: 1.0.0

`cube-stack-ha` is a **new chart** — there is no prior release to
upgrade from. If you were running the [Unreleased] HA work that lived
in `cube-stack@1.0.0` with `cubestore.ha.enabled=true`, this is the
chart you migrate to.

## Migrating from `cube-stack` with `cubestore.ha.enabled=true`

### Why a fresh install (not `helm upgrade`)

A `StatefulSet`'s `serviceName:` field is **immutable** in Kubernetes.
This chart's StatefulSet is bound to a new headless service
(`<rel>-cubestore-router-headless`, see A2 in
[plan](../../.claude/plans/frolicking-chasing-shamir.md)) which the
old `cube-stack@1.0.0` HA path didn't have. `helm upgrade` won't be
able to flip the field; it'd error out.

So the migration is "install fresh, copy data over from PVC backup".

### Pre-flight

- **Backup the metastore PVC** before you start. The router PVC holds
  the RocksDB metastore plus the Raft log; both are needed for a
  consistent restore. (The B2 backup CronJob — coming in a later PR —
  will automate this; for now, snapshot the PVC manually via your
  cloud provider's volume snapshot API or `kubectl cp` the data dir
  out.)
- **Verify Raft health** before draining: every router pod should
  report stable `cs_raft_term` for ≥30s, with exactly one
  `cs_raft_is_leader=1`. If the cluster is mid-election, wait it out.
- **Note the leader pod** so you can prefer it as the source of the
  PVC backup.

### Steps

```bash
# 1. snapshot every router PVC
kubectl -n cube get pvc -l app.kubernetes.io/component=cubestore-router

# 2. uninstall the old release (but keep PVCs)
helm uninstall cube -n cube
# StatefulSet PVCs survive the uninstall by default; verify:
kubectl -n cube get pvc

# 3. install cube-stack-ha
helm dependency update charts/cube-stack-ha
helm install cube-ha charts/cube-stack-ha \
  -f charts/cube-stack-ha/values.yaml \
  -f your-overrides.yaml \
  --namespace cube-ha --create-namespace --wait --timeout 5m

# 4. verify the cluster forms
make ha-verify
```

### Expected differences vs. `cube-stack@1.0.0` HA path

- New headless service `cube-ha-cube-stack-ha-cubestore-router-headless`
  exists in addition to the regular ClusterIP service (the headless one
  carries Raft traffic only, not client meta/http/mysql/status).
- StatefulSet `serviceName:` is the headless name.
- `CUBESTORE_RAFT_PEERS` env DNS uses the headless service. The
  per-pod A records resolve identically to before, just under a
  different domain.
- Router pods get a `requiredDuringSchedulingIgnoredDuringExecution`
  podAntiAffinity by default (hostname). On single-node clusters
  (kind/docker-desktop), set `cubestore.antiAffinity.type: preferred`
  in your overrides — the included `values-ha-test.yaml` already does.

### Rolling restart procedure

For routine restarts (image bump, config change) once
`cube-stack-ha@1.0.0` is in place, follow the
[HA-UPGRADE.md](docs/HA-UPGRADE.md) runbook (added in PR-4).

### Release tag

`cube-stack-ha-v1.0.0` publishes to
`oci://ghcr.io/<owner>/charts/cube-stack-ha:1.0.0`.
