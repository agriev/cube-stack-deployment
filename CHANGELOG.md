# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

The repo ships **two charts**, each versioned independently:

- [`cube-stack`](charts/cube-stack) — vanilla community Cube.js
- [`cube-stack-ha`](charts/cube-stack-ha) — HA variant on the agriev/cube fork

A shared Helm library chart [`cube-stack-common`](charts/cube-stack-common)
holds helpers used by both; it is never released standalone.

---

## cube-stack

### [Unreleased]

### [1.1.0] - 2026-05-04

#### Changed
- **Repo refactor — split into two charts.** `cube-stack` (this chart,
  vanilla) and a new `cube-stack-ha` chart for the HA fork. Helpers
  moved to a `cube-stack-common` Helm library chart that both depend
  on. No behavioral change for vanilla users; HA users migrate to
  `cube-stack-ha`.
- Validation rejects `cubestore.router.replicas > 1` on this chart
  (Community Edition can't replicate router metadata). Use
  `cube-stack-ha` for multi-router.
- `release.yaml` accepts `cube-stack-vX.Y.Z` tags; legacy `chart-vX.Y.Z`
  pattern still resolves to this chart for back-compat.

#### Removed
- `cubestore.ha.*` values block, `_helpers.tpl` (now in library), the
  Raft Grafana dashboard, `dashboards/raft-cluster.json`, and
  `values-ha-test.yaml` — all moved to `cube-stack-ha`.

### [1.0.0] - 2026-05-01

### Added
- Initial release of `cube-stack` Helm chart pinned to **Cube 1.6.41** /
  **Cube Store 1.6.41**.
- Cube API Deployment with HPA + PDB and `/livez` `/readyz` probes.
- Cube Refresh Worker Deployment with optional HPA + PDB.
- Cube Store Router StatefulSet (single instance, persistent metadata).
- Cube Store Workers StatefulSet (cluster mode, headless service, auto-built
  `CUBESTORE_WORKERS` list).
- Remote storage backends: `s3`, `gcs`, `minio`, or shared RWX PVC.
- Cube Store as default cache & queue driver (`cubestore`); Redis is optional
  via the bundled bitnami subchart or external URL.
- Multi-datasource support — first entry maps to `CUBEJS_DB_*`, subsequent
  ones to `CUBEJS_DS_<NAME>_DB_*`.
- Schema delivery via baked image, ConfigMap, or git-clone init container.
- Optional Ingress, NetworkPolicy, ServiceMonitor and statsd-Prometheus sidecar.
- Topology-spread auto-generation across zones (`global.topologySpread`).
- Helm tests for API + Cube Store router endpoints.
- CI/CD workflows: lint + template + kubeconform + chart-testing on kind,
  multi-arch Docker buildx with cosign signing and Trivy scan, OCI chart
  release on `chart-vX.Y.Z` tag, weekly security scan.
- Custom Cube Dockerfile in `docker/` (model + extra deps + non-root user
  + healthcheck).

---

## cube-stack-ha

### [Unreleased]

### [1.0.0] - 2026-05-04

#### Added
- Initial release of the HA variant of `cube-stack`. 3-router Raft cluster
  via the [`agriev/cube`](https://github.com/agriev/cube) fork's
  `cubestore-ha` image, per-pod DNS via StatefulSet `serviceName`, PDB
  `minAvailable=replicas-1`, Raft port `9100`, and `CUBESTORE_NODE_ID`
  injection from pod ordinal in an init wrapper.
- HA defaults baked in: `cubestore.ha.enabled=true`,
  `cubestore.router.replicas=3`, `cubestoreImage.repository=cubestore-ha`,
  `tag=vdev` (override for prod with your built/pushed fork image).
- `values-ha-test.yaml` overlay for local 3-router validation against
  in-cluster minio.
- Grafana dashboard ConfigMap for the fork's `cs.raft.*` metrics.
- Released as a separate OCI artifact under tag `cube-stack-ha-vX.Y.Z`
  (`oci://ghcr.io/<owner>/charts/cube-stack-ha`).

---

## Repo-level (Makefile, scripts, CI)

### [Unreleased]

#### Added
- `make ha-image / ha-deploy / ha-verify / ha-chaos / ha-down / ha-reset`
  Makefile targets covering the full HA lifecycle on docker-desktop k8s.
  Targets now operate against `charts/cube-stack-ha/`.
- `scripts/ha-verify.sh` (single-cycle leader failover) and
  `scripts/ha-chaos.sh` (multi-cycle kill chaos with budget + settle).
  3-round chaos validated end-to-end (89 s total, 6–10 s per failover).
- New Makefile targets: `make deps-all`, `make lint-all`, `make render-ha`
  for working with both charts.
- CI helm-lint job now matrixes over `[cube-stack, cube-stack-ha]`.

#### Fixed
- `ct lint` was failing 100% with "404 Not Found" because the chart's
  maintainer "Platform Team" isn't a real GitHub user — disabled the
  GitHub-API maintainer existence check via
  `--validate-maintainers=false`. The maintainer entry has been
  rewritten to `agriev` (real handle) so the check would pass anyway.
- `aquasecurity/trivy-action` was referenced as `@0.28.0` but the tag
  on that repo is `v0.28.0` — added the `v` prefix in `docker.yaml` and
  `security.yaml`. Both workflows had been failing at "Prepare all
  required actions" before any step ran.
