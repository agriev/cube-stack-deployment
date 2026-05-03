# cube-stack

Production-grade, scalable Helm chart **+** build pipelines for the
[Cube.js Community Edition](https://cube.dev/) semantic layer on Kubernetes.

| Component | Image | Purpose |
| --- | --- | --- |
| Cube API | `cubejs/cube` | Request-serving Pods (REST/GraphQL/SQL APIs) — scaled by HPA |
| Cube Refresh Worker | `cubejs/cube` | Background pre-aggregation builder (`CUBEJS_REFRESH_WORKER=true`) |
| Cube Store Router | `cubejs/cubestore` | Cluster metadata + query planner |
| Cube Store Workers | `cubejs/cubestore` | Distributed query execution (StatefulSet) |
| Redis (optional) | `bitnami/redis` | Legacy queue/cache driver — Cube Store handles this by default |

Pinned to **Cube 1.6.41** (latest stable as of 2026-05-01). Override with one
flag — see [Versioning](#versioning).

---

## Quick start

The fastest way to see Cube running on a cluster (zero external dependencies —
uses an in-memory DuckDB datasource and a bundled "orders" demo cube):

```bash
helm dependency update charts/cube-stack
helm upgrade --install cube charts/cube-stack \
  -f charts/cube-stack/values.yaml \
  -f charts/cube-stack/values-quickstart.yaml \
  -n cube --create-namespace --wait
kubectl -n cube port-forward svc/cube-cube-stack-api 4000
open http://localhost:4000      # Cube Playground
```

Standard deploy with overrides (the chart will refuse to install if you
forget the datasource — see [Will it boot out of the box?](#will-it-boot-out-of-the-box)):

```bash
make deps                       # pull subcharts
make lint                       # validate values + templates
make render-prod                # inspect what'll be applied
make install OVERLAY=my.yaml    # helm upgrade --install
make test                       # /livez + /readyz smoke tests
```

End-to-end on a local kind cluster (Postgres + dev overlay):

```bash
make kind-up
make kind-deploy
make test
make kind-down
```

---

## Architecture compatibility (Apple Silicon, Graviton, non-AVX CPUs)

`cubejs/cube` ships multi-arch (`linux/amd64` + `linux/arm64`).
**`cubejs/cubestore` does NOT** — its main tags are linux/amd64 only.

For ARM64 nodes (Apple Silicon kind/minikube, AWS Graviton, ARM clouds) use:

```yaml
cubestoreImage:
  archSuffix: "-arm64v8"     # tag becomes v1.6.41-arm64v8
```

For amd64 CPUs without AVX (some older CPUs / nested VMs):

```yaml
cubestoreImage:
  archSuffix: "-non-avx"
```

The chart auto-fails the install on `ImagePullBackOff` so you'll know
within 30 seconds — but better to set the suffix up front. The
quickstart overlay does this automatically when it detects ARM during CI.

---

## Will it boot out of the box?

Short answer: **no, by design** — and that's the same trade-off the official
Cube docs make.

`helm install cube ./charts/cube-stack` with **default values fails** with:

```
datasources.default.host is required (or enable quickstart.enabled=true to deploy with the bundled demo schema)
```

There's no sensible default for "which warehouse should Cube talk to" —
silently starting a Cube that can't answer queries is worse than refusing
to install. Three resolutions:

| Goal | Command |
| --- | --- |
| Demo / smoke test (no DB, in-memory DuckDB, fake `orders` cube) | `helm install … -f values-quickstart.yaml` |
| Local kind cluster against a real Postgres | `make kind-deploy` (applies `examples/postgres-dev.yaml` + `values-dev.yaml`) |
| Production | configure `datasources.<name>` (host + creds), schema source (`schema.configMap` / `schema.git` / baked image), and a remote storage backend for Cube Store |

The minimum **must-set** keys for a healthy production install:

```yaml
quickstart: { enabled: false }
cube:
  apiSecret: "<openssl rand -hex 64>"          # or apiSecretFromSecret.name
  preAggregationsSchema: "prod_pre_aggregations"
datasources:
  default:
    type: postgres
    host: ...                                   # required
    database: ...
    user: ...
    existingSecret: ...                         # holds password
schema:
  configMap: { enabled: true, inline: { ... } } # OR schema.git OR baked image
cubestore:
  workers:    { replicas: 2 }                   # ≥ 2 for cluster mode
  remoteStorage:
    type: s3                                    # OR gcs (NOT minio for prod)
    s3: { bucket: ..., region: ..., existingSecret: ... }
```

`helm template … | kubeconform` runs in CI for every overlay, so a
misconfigured release fails before it reaches the cluster.

---

## Production checklist

Aligned with [Cube's own production guide](https://cube.dev/docs/product/caching/running-in-production)
and [environment variable reference](https://cube.dev/docs/product/configuration/reference/environment-variables).

### Infrastructure

- [ ] Cube Store **cluster mode** (`cubestore.workers.replicas ≥ 2`). OSS Cube Store **does not replicate** — losing the router or any worker downs the cluster, so cluster mode is about throughput, not HA. (For genuine router HA, see [HA mode](#cube-store-ha-mode-experimental) below.)
- [ ] Cube Store remote storage on **S3 or GCS** (not MinIO — community-supported, no consistency guarantees per Cube docs).
- [ ] Cube Store **export bucket ≠ persistent bucket** (`datasources.<n>.export.bucket` and `cubestore.remoteStorage.s3.bucket` MUST differ).
- [ ] Cube Store **isolated network** — no NetworkPolicy ingress from outside the cube namespace; Cube Store has no auth of its own.
- [ ] Pin both images to the same tag (`global.imageTag: vX.Y.Z`) — Cube and Cube Store ship in lock-step.

### Capacity

- [ ] API Pods: 2+ replicas, **2 CPU + 3 GiB RAM** minimum each (Cube docs).
- [ ] Refresh worker: **6 GiB RAM** allocation; raise `refreshWorker.concurrency` for partitioned schedules.
- [ ] Cube Store router: **4 CPU + 8 GiB RAM** (the docs' floor).
- [ ] Cube Store workers: **4 CPU + 8 GiB RAM** each, ≥ 2 replicas. Partition count of any pre-agg should be ≤ workers.replicas for fan-out efficiency.

### Tuning

- [ ] `cube.preAggregationsSchema` set to a stable schema name in your warehouse.
- [ ] `cube.dbQueryTimeout` ≥ longest pre-agg build time.
- [ ] `cube.maxSessions` capped at the warehouse's connection budget.
- [ ] `refreshWorker.queriesPerAppId` raised in multi-tenant deployments.
- [ ] `cubestore.queryTimeout` and `cubestore.jobRunners` tuned per workload.
- [ ] `CUBEJS_DB_EXPORT_BUCKET` configured for Snowflake / BigQuery / Redshift (set `datasources.<n>.export.*` instead of `extraEnv`).

### Security

- [ ] `cube.apiSecret` from external secret (Sealed Secret / External Secrets / Vault), not inline.
- [ ] JWT auth enabled (`cube.jwt.enabled=true`) — never expose Cube to the internet without it.
- [ ] SQL API gated by `cube.sqlAuth` if `pgSqlPort` / `sqlPort` exposed.
- [ ] `cube.devMode: false` (`CUBEJS_DEV_MODE=false`) — default in production overlay.
- [ ] `cube.telemetry: false` for air-gapped clusters.
- [ ] `networkPolicy.enabled: true` — restrict ingress to dashboards / BI tools.
- [ ] Cosign-signed images (the `docker.yaml` workflow does this) verified by an admission controller.

### Observability

- [ ] `metrics.statsdExporter.enabled: true` (Cube Store StatsD → Prometheus).
- [ ] `metrics.serviceMonitor.enabled: true` for the Prometheus Operator.
- [ ] Track key SLIs: `cubejs_pre_aggregation_build_duration`, refresh worker queue depth, Cube Store query timeouts.

---

## Cube Store HA mode (experimental)

Upstream OSS Cube Store has a single-router single-point-of-failure: all
metadata lives in one RocksDB instance, and pod loss makes the cluster
unqueryable until k8s reschedules and re-attaches the PVC. The
[`agriev/cube`](https://github.com/agriev/cube) fork adds embedded Raft
replication (no external coordinator) to the router. This chart wires that
fork in via `cubestore.ha.enabled=true`.

```bash
# Build the fork's image
make ha-image                         # → cubestore-ha:vdev

# Deploy a 3-router HA cluster (namespace cube-ha)
make ha-deploy

# Verify single-cycle failover (kill leader → new leader)
make ha-verify

# Multi-cycle chaos (3 rounds; recovers in ~6–10 s per round)
make ha-chaos
```

What flips when `cubestore.ha.enabled=true`:

- `replicas: 3` enforced (chart fails install on `< 3` or even values).
- Per-pod headless DNS via the StatefulSet `serviceName`.
- `CUBESTORE_NODE_ID` derived from pod ordinal in an init wrapper.
- `CUBESTORE_RAFT_PEERS` rendered from the replica count.
- PDB `minAvailable = replicas - 1` (quorum protection).
- Raft port `9100` opened.

Production caveats:

- Workers are unchanged — partition replication is Phase 2 in the fork.
- Reads route to the leader; followers don't serve queries in v1.
- The fork rebases on upstream Cube quarterly; pin both `image.tag` and
  `cubestoreImage.tag` to the same release.

See the fork's [`HA.md`](https://github.com/agriev/cube/blob/ha-main/HA.md)
and [migration guide](https://github.com/agriev/cube/blob/ha-main/docs/ha/MIGRATION.md)
for protocol details.

---

## Anti-patterns (from Cube docs)

| Anti-pattern | Why it's bad | Mitigation in this chart |
| --- | --- | --- |
| Single Cube Store node in production | Single point of failure + bottleneck | `cubestore.workers.replicas ≥ 2` enforced via NOTES.txt warning |
| Sharing export bucket and persistent bucket | Concurrent reads/writes corrupt state | `datasources.<n>.export.bucket` is separate from `cubestore.remoteStorage.s3.bucket` |
| MinIO for persistent storage | Community contribution, no consistency guarantees | values.yaml documents `s3` / `gcs` as preferred; `minio` listed but flagged in docs |
| Cube Store exposed without network controls | No built-in auth | Optional `networkPolicy.enabled: true` |
| Memory cache driver in production | Loses queue on Pod restart | Default `cube.cacheAndQueueDriver=cubestore` |
| `CUBEJS_DEV_MODE=true` in production | Disables auth, exposes playground | Default `cube.devMode: false`; `quickstart` overlay opts in explicitly |
| Heavy non-partitioned pre-aggregations | Query timeouts, single-worker hotspot | `cube.dbQueryTimeout`, doc the partition rule |
| High-cardinality dimensions in pre-aggs | Inflates table size | Surfaced in docs |

---

## Extensibility scenarios

The chart is engineered around **swap points**, not forks. Each scenario
below is supported without modifying templates.

### 1. Custom Cube image (drivers, monkey-patches, baked schema)

Build [`docker/Dockerfile`](docker/Dockerfile) and point `image.repository` at
your registry. The CI workflow handles multi-arch buildx + cosign + Trivy.

```yaml
image:
  repository: ghcr.io/my-org/cube
  tag: v1.6.41-3
```

Add npm deps in [`docker/package.json`](docker/package.json) (e.g. a custom
auth provider, a patched driver, OpenTelemetry).

### 2. Custom `checkAuth` (JWT, mTLS, custom claim mapping)

Mount your own `cube.js` via `schema.configMap.inline`:

```yaml
schema:
  configMap:
    enabled: true
    inline:
      cube.js: |
        const jwt = require('jsonwebtoken');
        module.exports = {
          checkAuth: async (req, auth) => {
            const decoded = jwt.verify(auth, process.env.CUBEJS_JWT_KEY);
            req.securityContext = { tenant_id: decoded.tenant };
          },
        };
      model/orders.yml: |
        ...
```

### 3. Multi-tenancy via `scheduledRefreshContexts`

Refresh different tenants in parallel:

```yaml
schema:
  configMap:
    enabled: true
    inline:
      cube.js: |
        module.exports = {
          contextToAppId: ({ securityContext }) => `app_${securityContext.tenant_id}`,
          contextToOrchestratorId: ({ securityContext }) => `orch_${securityContext.tenant_id}`,
          scheduledRefreshContexts: async () => [
            { securityContext: { tenant_id: 'acme' } },
            { securityContext: { tenant_id: 'globex' } },
          ],
        };

refreshWorker:
  replicas: 3                         # one Pod per ~10 tenants is a good rule
  concurrency: 6
  queriesPerAppId: 10
```

### 4. Federation across Cube instances

Two Cubes can read each other's data via the SQL API. Deploy two releases
in different namespaces:

```bash
helm install cube-revenue ./charts/cube-stack -f revenue.yaml -n revenue
helm install cube-product ./charts/cube-stack -f product.yaml -n product
# In product's cube.js add the SQL connection to revenue's pgSqlPort.
```

### 5. Custom drivers

Drop them into [`docker/package.json`](docker/package.json):

```json
{ "dependencies": { "@cubejs-backend/my-custom-driver": "0.1.0" } }
```

Then in `cube.js`:

```js
const Driver = require('@cubejs-backend/my-custom-driver');
module.exports = { driverFactory: () => new Driver(...) };
```

### 6. Sidecars for cloud SQL proxy / Vault Agent / OTel collector

```yaml
api:
  sidecars:
    - name: cloud-sql-proxy
      image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.13.0
      args: [my-project:us-east1:db, "--auto-iam-authn"]
      securityContext: { runAsNonRoot: true }
  extraVolumes: []
  initContainers:
    - name: vault-agent
      image: hashicorp/vault:1.18
      ...
```

### 7. External Secrets / Sealed Secrets

Every credential field has an `existingSecret` companion:

```yaml
cube:
  apiSecretFromSecret: { name: cube-api, key: secret }
  jwt:
    keyFromSecret:    { name: cube-jwt, key: public.pem }
datasources:
  default:
    existingSecret:    cube-pg
    export:
      aws:
        existingSecret: cube-aws
```

The chart only renders chart-managed Secrets when *no* `existingSecret`
is set — there's no double-allocation.

### 8. Custom storage backends

Cube Store remote storage is exhaustive: pick `s3` / `gcs` / `minio` /
`shared-pvc` per the [`cubestore.remoteStorage.type` block](charts/cube-stack/values.yaml).
For Azure Blob, set `cubestore.extraEnv` with `CUBESTORE_AZURE_*` (Cube
docs cover the variable names).

### 9. Custom metrics / dashboards

`metrics.serviceMonitor` ships out of the box. For a Grafana dashboard,
toggle `metrics.grafanaDashboard.enabled` and provide your own JSON via
`extraManifests` (or import [the official dashboard](https://grafana.com/grafana/dashboards/14741-cube-store/)
through your Grafana provisioning).

### 10. ArgoCD / Flux

The chart is a single rooted directory — point an `Application` /
`HelmRelease` at `charts/cube-stack` and supply your overlay via
`spec.source.helm.valuesFiles`. The OCI release workflow
(`chart-vX.Y.Z` tag) publishes signed packages to
`oci://ghcr.io/<owner>/charts/cube-stack` for declarative consumption.

---

## Layout

```
.
├── charts/
│   └── cube-stack/             # the Helm chart
│       ├── Chart.yaml
│       ├── values.yaml         # ★ single source of truth
│       ├── values-prod.yaml    # production overlay
│       ├── values-dev.yaml     # local kind/minikube overlay
│       └── templates/
├── docker/                     # custom Cube image (model + extra deps)
│   ├── Dockerfile
│   ├── cube.js
│   └── model/
├── examples/                   # ready-to-mix overlays per data source
├── .github/workflows/
│   ├── ci.yaml                 # lint + template + kubeconform + ct install on kind
│   ├── docker.yaml             # multi-arch image build, signing, Trivy scan
│   ├── release.yaml            # OCI chart push on `chart-vX.Y.Z` tag
│   └── security.yaml           # weekly Trivy + kube-linter on rendered manifests
├── Makefile
└── README.md
```

---

## Architecture

```
                ┌────────────────────────────────────┐
                │  ingress (optional)                │
                └─────────────┬──────────────────────┘
                              │ HTTPS / SQL
              ┌───────────────▼───────────────┐
              │ Cube API (Deployment + HPA)   │ ←─ /livez, /readyz
              └─┬──────────┬─────────────────┬┘
   queries via  │          │ scheduled jobs  │ env vars
   gRPC/HTTP    │          ▼                 │
              ┌─▼─┐  ┌─────────────────┐     │
              │ . │  │ Refresh Worker  │     │
              │ . │  └────────┬────────┘     │
              │ . │           │              │
              │ . │           ▼              ▼
              │ . │  ┌─────────────────────────────────┐
              │ . │  │ Cube Store Router (StatefulSet)│ — metadata + planner
              │ . │  └────────┬────────────────────────┘
              │ . │           │ control plane
              │ . │  ┌────────▼────────────────────────┐
              │ . │  │ Cube Store Workers (StatefulSet,│ — distributed exec
              │ . │  │ headless service, N replicas)   │
              │ . │  └────────┬────────────────────────┘
              │ . │           │
              │ . │  ┌────────▼────────┐
              │ . │  │ Remote storage  │ — S3 / GCS / MinIO / shared PVC
              │ . │  └─────────────────┘
              │ . │
              │ . │  ┌───────────────────────┐
              │ . └─►│ Upstream data sources │ — Postgres / Snowflake / ClickHouse / ...
              └─────►└───────────────────────┘
```

### Why Cube Store cluster mode?

A single Cube Store node is a single point of failure and a hard bottleneck on
sub-second analytics. Cluster mode (one router + N workers) is the
[official recommendation for production](https://cube.dev/docs/product/caching/running-in-production).
This chart sets it up out of the box:

- the router is a StatefulSet exposing `meta`, `http`, `mysql`, `status` ports
  via a regular ClusterIP Service so workers and the API can resolve it by name;
- workers are a StatefulSet with a **headless** Service so each Pod gets a
  stable FQDN of the form `<release>-cube-stack-cubestore-workers-<N>.<release>-cube-stack-cubestore-workers-headless`;
- the chart auto-fills `CUBESTORE_WORKERS` and `CUBESTORE_META_ADDR` for both
  sides so you never have to hand-build the comma-separated list.

### Cache & queue driver

Since Cube 0.32 the cache and queue can run on Cube Store itself, removing
Redis from the critical path. The chart defaults to that
(`cube.cacheAndQueueDriver=cubestore`). If you must keep Redis, set the value
to `redis` and either flip `redis.enabled=true` (bitnami subchart) or point
`redis.external.url` at your existing Redis.

---

## One config to rule them all

Every component is parameterised in
[`charts/cube-stack/values.yaml`](charts/cube-stack/values.yaml). The most
relevant top-level keys:

| Key | What it controls |
| --- | --- |
| `global.imageTag` | Pin Cube + Cube Store to the same version everywhere |
| `global.topologySpread` | `soft` / `hard` — auto-generates topology spread constraints across zones |
| `cube.*` | Cube core settings (ports, secrets, cache driver, JWT, schema path) |
| `image.*`, `cubestoreImage.*` | Override registries (e.g. for the custom image built from `docker/Dockerfile`) |
| `schema.configMap` / `schema.git` | Where Cube finds your model files |
| `api.*` | Cube API replicas, resources, HPA, PDB, probes |
| `refreshWorker.*` | Refresh worker replicas, resources, HPA, PDB |
| `cubestore.router.*` / `cubestore.workers.*` | StatefulSet sizing, persistence, probes |
| `cubestore.remoteStorage.*` | S3 / GCS / MinIO / shared-PVC backend |
| `datasources.*` | One or more data sources (postgres / snowflake / bigquery / clickhouse / …) |
| `redis.*` | Bundled or external Redis (legacy driver only) |
| `ingress.*` | HTTP/REST ingress |
| `metrics.*` | StatsD-to-Prometheus sidecar + ServiceMonitor + Grafana dashboard |
| `networkPolicy.*` | NetworkPolicy locking down ingress between components |

Overlays:

- `values-prod.yaml` — HA, multi-zone, S3 remote storage, ServiceMonitor, NetworkPolicy
- `values-dev.yaml` — single-replica, RWO PVC, kind/minikube friendly
- `examples/values-*.yaml` — drop-in overlays for Snowflake / ClickHouse / multi-datasource setups

---

## Scaling

### Cube API

Defaults: HPA on, min 2, max 10 replicas, target 70 % CPU + 80 % memory.

```yaml
api:
  replicas: 3              # baseline
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 30
    targetCPUUtilizationPercentage: 60
    behavior:
      scaleDown:
        stabilizationWindowSeconds: 600
```

### Refresh worker

Refresh workers are stateful in practice (each one schedules a slice of
pre-aggregations), so HPA is **off by default**. Enable when you have
clearly partitioned schedules:

```yaml
refreshWorker:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 6
```

### Cube Store

Scale by adding workers — the chart re-renders `CUBESTORE_WORKERS` for you:

```yaml
cubestore:
  workers:
    replicas: 8
    resources:
      requests: { cpu: "4", memory: 16Gi }
      limits:   { cpu: "8", memory: 32Gi }
```

> Adding workers is a rolling restart of Cube Store. Drain queries first if
> you can — Cube Store is push-style and will retry, but in-flight queries may
> error during the restart window.

---

## Schema delivery

Three options — pick whichever fits your release process best.

1. **Custom image** (default). Build [`docker/Dockerfile`](docker/Dockerfile),
   point `image.repository` at your registry. CI in
   `.github/workflows/docker.yaml` does multi-arch build, cosign sign, Trivy
   scan, and pushes tags `vX.Y.Z`, `vX.Y`, `vX`, `sha-…` to GHCR.

2. **ConfigMap**:
   ```yaml
   schema:
     configMap:
       enabled: true
       inline:
         cube.js: |
           module.exports = { schemaPath: 'model' };
         model/orders.yml: |
           cubes:
             - name: orders
               sql_table: public.orders
               measures: [{ name: count, type: count }]
   ```

3. **Git**:
   ```yaml
   schema:
     git:
       enabled: true
       repoUrl: git@github.com:my-org/cube-models.git
       ref: main
       subPath: cube
       auth:
         existingSecret: cube-git-key
         sshKeyKey: id_rsa
   ```

---

## Versioning

| Knob | Effect |
| --- | --- |
| `global.imageTag` | Pin Cube + Cube Store to one version (e.g. `v1.6.41`) |
| `image.tag` | Override Cube image tag specifically |
| `cubestoreImage.tag` | Override Cube Store image tag specifically |
| `Chart.yaml`'s `appVersion` | Default fallback for both |

Bump path:

```bash
# Update appVersion + global.imageTag in Chart.yaml + values.yaml,
# bump the chart version in Chart.yaml, then:
git tag chart-v1.0.1
git push --tags
# .github/workflows/release.yaml packages and pushes the chart to OCI GHCR.
```

---

## Security defaults

- `runAsNonRoot: true`, `runAsUser: 1000`, `fsGroup: 1000`
- `allowPrivilegeEscalation: false`, drop **all** capabilities
- Seccomp `RuntimeDefault`
- Read-only root FS is **off** (Cube writes to `/cube/conf` at startup) but is
  toggleable via `containerSecurityContext.readOnlyRootFilesystem`
- Optional `NetworkPolicy` (off by default)
- Image SBOM + signature via cosign keyless (`docker.yaml` workflow)
- Weekly Trivy + kube-linter SARIF uploads (`security.yaml` workflow)

---

## Local development

```bash
brew install helm kubectl kind kubeconform
make deps lint kubeconform     # offline checks
make kind-up                   # spin up kind cluster
make kind-deploy               # postgres + cube-stack (dev overlay)
kubectl -n cube port-forward svc/cube-cube-stack-api 4000
open http://localhost:4000     # Cube playground
make test                      # /livez + /readyz smoke tests
make kind-down
```

---

## CI/CD

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`ci.yaml`](.github/workflows/ci.yaml) | push / PR on `charts/**` | helm lint + template + kubeconform; `chart-testing` lint + install on kind |
| [`docker.yaml`](.github/workflows/docker.yaml) | push / tag / dispatch | multi-arch buildx → GHCR; SBOM + cosign signing; Trivy scan |
| [`release.yaml`](.github/workflows/release.yaml) | tag `chart-vX.Y.Z` | helm package, push to `oci://ghcr.io/<owner>/charts`, GitHub Release |
| [`security.yaml`](.github/workflows/security.yaml) | weekly + PR | Trivy config scan on rendered manifests + kube-linter SARIF |

---

## Reference: data source environment variables

The chart auto-translates `datasources.<name>.*` into `CUBEJS_DB_*` (for the
first entry — the default data source) or `CUBEJS_DS_<NAME>_DB_*` for
subsequent entries. Anything Cube needs that the chart doesn't know about
goes through `extraEnv`:

```yaml
datasources:
  default:
    type: bigquery
    extraEnv:
      - name: CUBEJS_DB_BQ_PROJECT_ID
        value: my-project
      - name: CUBEJS_DB_BQ_KEY_FILE
        value: /etc/cube/bq.json
    # Mount the key via cube.extraEnvFrom or schema.configMap as needed.
```

See [Cube docs](https://cube.dev/docs/product/configuration/reference/environment-variables)
for the canonical list.

---

## Sources

- [Cube documentation — production deployment](https://cube.dev/docs/product/deployment/core)
- [Cube Store cluster guide](https://cube.dev/docs/product/caching/running-in-production)
- [Reference community charts (gadsme/charts)](https://github.com/gadsme/charts)
- [Reference community charts (narioinc/cube-helm)](https://github.com/narioinc/cube-helm)
