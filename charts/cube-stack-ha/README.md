# cube-stack

Production-grade Helm chart for the Cube.js Community Edition semantic layer.

| Chart | App | Source |
| --- | --- | --- |
| `cube-stack 1.0.0` | `cube 1.6.41` / `cubestore 1.6.41` | https://github.com/cube-js/cube |

```bash
helm dependency update charts/cube-stack
helm upgrade --install cube charts/cube-stack \
  -n cube --create-namespace \
  -f charts/cube-stack/values.yaml \
  -f charts/cube-stack/values-prod.yaml
```

See the [project README](../../README.md) for the full architecture, scaling
guidance, CI/CD details, and the complete reference of values.

## Components installed

| Component | Workload | Default replicas |
| --- | --- | --- |
| `cube-stack-api` | Deployment + HPA + Service + PDB | 2 → 10 |
| `cube-stack-refresh-worker` | Deployment | 1 |
| `cube-stack-cubestore-router` | StatefulSet + Service | 1 |
| `cube-stack-cubestore-workers` | StatefulSet + headless Service + PDB | 2 |
| Redis (optional) | bitnami subchart | — |

## Quick reference

| Operation | Command |
| --- | --- |
| Lint | `helm lint charts/cube-stack` |
| Render | `helm template demo charts/cube-stack` |
| Install | `helm upgrade --install cube charts/cube-stack -n cube --create-namespace` |
| Smoke tests | `helm test cube -n cube` |
| Uninstall | `helm uninstall cube -n cube` |

## Configuration

All settings live in [`values.yaml`](values.yaml). Top-level sections:

- `global`, `image`, `cubestoreImage` — image + naming + global topology spread
- `podSecurityContext`, `containerSecurityContext` — security defaults
- `cube` — Cube core env (ports, secrets, cache driver, JWT, telemetry, schema)
- `schema` — model delivery (`configMap` / `git`)
- `api` — Cube API: replicas, HPA, PDB, probes, resources, scheduling
- `refreshWorker` — same shape as `api`, but for the refresh worker
- `cubestore.router` / `cubestore.workers` — StatefulSet sizing + persistence
- `cubestore.remoteStorage` — `s3` / `gcs` / `minio` / `shared-pvc`
- `datasources` — one or more upstream databases
- `redis` — bundled subchart or external URL (legacy queue driver)
- `ingress`, `networkPolicy`, `metrics`, `tests` — peripheral concerns

Two ready-to-use overlays ship with the chart:

- [`values-prod.yaml`](values-prod.yaml) — multi-zone HA, S3 remote storage, ServiceMonitor, NetworkPolicy
- [`values-dev.yaml`](values-dev.yaml) — single-replica, RWO shared-pvc, kind/minikube

## License

Apache-2.0
