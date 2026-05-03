# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Cube Store **HA mode** wired through `cubestore.ha.enabled=true` —
  rendered StatefulSet runs 3 routers with embedded Raft replication
  (via the [`agriev/cube`](https://github.com/agriev/cube) fork's
  `cubestore-ha` image). Per-pod DNS via StatefulSet `serviceName`,
  PDB `minAvailable=replicas-1`, Raft port `9100`, and
  `CUBESTORE_NODE_ID` injection from pod ordinal in an init wrapper.
- `values-ha-test.yaml` overlay for local 3-router validation against
  in-cluster minio.
- `make ha-image / ha-deploy / ha-verify / ha-chaos / ha-down / ha-reset`
  Makefile targets covering the full HA lifecycle on docker-desktop k8s.
- `scripts/ha-verify.sh` (single-cycle leader failover) and
  `scripts/ha-chaos.sh` (multi-cycle kill chaos with budget + settle).
  3-round chaos validated end-to-end (89 s total, 6–10 s per failover).
- Grafana dashboard ConfigMap for the fork's `cs.raft.*` metrics
  (`charts/cube-stack/templates/cubestore/router-grafana-dashboard.yaml`).

## [1.0.0] - 2026-05-01

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
