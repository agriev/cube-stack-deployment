# cube-stack — troubleshooting

Issues common to both vanilla `cube-stack` and `cube-stack-ha` live
here. HA-specific problems (Raft elections, no-leader, election
storms) are in
[../../cube-stack-ha/docs/TROUBLESHOOTING.md](../../cube-stack-ha/docs/TROUBLESHOOTING.md).

For routine ops on a healthy HA cluster, see the runbook at
[../../cube-stack-ha/docs/HA-UPGRADE.md](../../cube-stack-ha/docs/HA-UPGRADE.md).

---

## ImagePullBackOff on ARM64 nodes

**Symptom.** Pod stuck in `ImagePullBackOff` shortly after
`helm install`. `kubectl describe pod` shows
`failed to find an image` or
`exec format error: cannot execute binary file`.

**Cause.** `cubejs/cubestore` ships **linux/amd64 only**. There's no
multi-arch manifest, so kubelet on Apple Silicon kind, AWS Graviton,
or any ARM64 cloud node tries to pull the wrong arch.

**Fix.** Set the arch suffix:

```yaml
cubestoreImage:
  archSuffix: "-arm64v8"   # tag becomes vX.Y.Z-arm64v8
```

For amd64 nodes without AVX (older CPUs, nested VMs):

```yaml
cubestoreImage:
  archSuffix: "-non-avx"
```

The chart auto-fails install on `ImagePullBackOff` after 30s, so this
shows up fast.

---

## Cube can't find the datasource

**Symptom.** Cube pods crash-loop with
`datasources.default.host is required (or enable quickstart...)`.

**Cause.** `_validations.tpl` enforces that every non-quickstart
install supplies a datasource. The default `values.yaml` has an empty
`datasources: {}`.

**Fix.** Either:

- Set a real datasource — see [../README.md](../README.md) §
  Datasources or one of the
  [examples](../../../examples/) overlays
  (`values-postgres-dev.yaml`, `values-snowflake.yaml`,
  `values-bigquery.yaml`, etc.).
- Or pass `--set quickstart.enabled=true` to install with the
  bundled DuckDB demo schema (zero external deps).

---

## OOM in the refresh worker

**Symptom.** Refresh worker pod gets `OOMKilled` repeatedly. Pre-
aggregations fall behind. `CubeRefreshWorkerCrashLooping`
PrometheusRule alert fires.

**Causes & fixes.**

- **Memory limit too low.** Default is 3Gi. Bump
  `refreshWorker.resources.limits.memory` and `requests.memory` if
  you have many large pre-aggs scheduled concurrently.
- **Too many pre-aggs running concurrently.** Lower
  `cubestore.jobRunners` (default unset; `cubestore.values.yaml`
  reference). Or scale horizontally via
  `refreshWorker.replicas` and `refreshWorker.hpa.enabled`.
- **One huge pre-agg.** Look at
  `kubectl logs <refresh-worker-pod> | grep "queryDuration"` for the
  outlier. Refactor the cube to partition the pre-agg.

---

## GCS / S3 credential errors

**Symptom.** Cube Store router logs show
`AccessDenied` or `InvalidAccessKeyId`. Cube API queries that hit a
pre-aggregation return 500 with `cubestore upload failed`.

**Causes & fixes.**

- **Credentials secret name doesn't match `existingSecret`.** Check:

  ```bash
  kubectl -n <ns> get secret <name>
  kubectl -n <ns> exec -ti <api-pod> -- env | grep CUBESTORE_AWS
  ```

- **Credentials expired** (especially short-lived AWS STS tokens).
  Bump `cubestore.awsCredsRefreshEveryMins` so the binary re-reads
  the secret periodically.

- **Bucket missing or in the wrong region.** Cube Store fails with a
  3xx redirect rather than a 4xx, so the error message is sometimes
  ambiguous.

  ```bash
  aws s3api get-bucket-location --bucket <name>
  ```

  Compare with `cubestore.remoteStorage.s3.region`.

---

## Cube API hangs / queries time out

**Symptom.** First query succeeds, subsequent queries hang
indefinitely or return 504. Cube Store router logs are quiet.

**Causes & fixes.**

- **Connection from Cube API to Cube Store using the wrong port.** The
  `CUBEJS_CUBESTORE_PORT` env should be the **HTTP** port (3030 by
  default), not the meta port (9999). The chart's `_helpers.tpl`
  derives this correctly via
  `cubeStack.cubeEnv.cubestore` — verify with
  `kubectl exec <api-pod> -- env | grep CUBESTORE`. If you've
  overridden `cube.cubestore.host` or similar, double-check the port.

- **Network policy blocking traffic.** If `networkPolicy.enabled:
  true` is set without ingress rules for the api → router path,
  packets silently drop. `kubectl describe networkpolicy`. As a quick
  test, `kubectl delete networkpolicy --all -n <ns>` and re-run the
  query; if it works, your policy spec is wrong.

---

## Helm install rejected with "cubestore.router.replicas must be 1"

**Symptom.** `helm install cube charts/cube-stack` fails with:

> Error: cubestore.router.replicas must be 1 in the vanilla
> cube-stack chart...

**Cause.** Vanilla Cube Store CE can't replicate router metadata. A
2- or 3-router setup with the upstream image silently runs as N
independent stores that drift apart on writes.

**Fix.** Either keep `replicas: 1` (the chart default) or switch to
the `cube-stack-ha` chart (Raft-replicated routers via the agriev/cube
fork).

---

## Cube Playground returns "Schema not found"

**Symptom.** `/playground` loads but every cube shows
`Cannot find schema`.

**Causes & fixes.**

- **`schema` block disabled.** Check `schema.configMap.enabled`,
  `schema.git.enabled`, or `quickstart.enabled` — at least one must
  be true (or the schema baked into a custom image at
  `/cube/conf/model`).
- **`schema.configMap` is empty.** Helm doesn't validate ConfigMap
  contents. Look at the rendered ConfigMap:

  ```bash
  kubectl -n <ns> get configmap <rel>-cube-stack-schema -o yaml
  ```

- **git-clone init container failed.** `kubectl describe pod
  <api-pod>` and look at `init-containers/git-clone` events. Most
  common: SSH key permissions (must be 0400 — the chart sets
  `defaultMode: 0400`, but if you supply a `Secret` directly check
  the file mode).

---

## Ingress 502s

**Symptom.** Ingress routes `/` to Cube but returns 502.

**Causes & fixes.**

- **Backend port mismatch.** The api Service exposes port 4000;
  ingress's `service.port.number` must match. The chart helper
  resolves this automatically — verify via
  `kubectl describe ingress`.
- **Slow startup.** First request after a cold start can take
  >30s on a large schema. Bump
  `api.startupProbe.failureThreshold`.

---

## See also

- [HA-specific issues](../../cube-stack-ha/docs/TROUBLESHOOTING.md) —
  Raft elections, leader flapping, election storms, headless service
  endpoints.
- [HA operations runbook](../../cube-stack-ha/docs/HA-UPGRADE.md) —
  rolling restarts, drains, backups before risky changes.
- [Repo README](../../../README.md) — chart overview and quickstart.
