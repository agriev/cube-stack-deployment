# Chart split: from one chart with a flag to two charts

This repo used to ship a single chart, `cube-stack`, that toggled HA on
via `cubestore.ha.enabled=true`. As of `cube-stack@1.1.0` /
`cube-stack-ha@1.0.0` it ships two charts plus a private library.

## What it looks like now

```
charts/
├── cube-stack-common/      ← Helm library chart (helpers only, never released standalone)
├── cube-stack/             ← vanilla community Cube.js, single router
└── cube-stack-ha/          ← HA on the agriev/cube fork, 3-router Raft
```

Each concrete chart depends on `cube-stack-common` via a local
`file://` repository entry. There's no public registry for the
library; consumers see only `cube-stack` or `cube-stack-ha` as a
single-artifact OCI install.

## Why split

- **Two product postures.** Vanilla wants HA *off* by default (the
  Community Edition can't replicate router metadata). HA wants HA *on*
  by default (it's the entire point). A single chart with a flag
  forced both audiences to navigate the other one's surface.
- **Two image dependencies.** Vanilla uses `cubejs/cubestore` (multi-arch
  upstream). HA uses `cubestore-ha` (the agriev/cube fork's image,
  built locally with `make ha-image` or pushed to your registry). The
  default `cubestoreImage.repository` differs by chart.
- **Two release cadences.** HA work moves fast (raft fork iterates
  weekly). Vanilla is a thin wrapper over upstream Cube and tracks
  upstream releases. Independent versioning lets each move at its own
  pace without dragging the other.
- **Cleaner UX.** Non-HA users never see HA validation errors, env
  vars, or PDB quirks. HA users don't have to remember the toggle.

## Tag conventions

| Tag pattern | Publishes |
|---|---|
| `cube-stack-vX.Y.Z` | `oci://ghcr.io/<owner>/charts/cube-stack:X.Y.Z` |
| `cube-stack-ha-vX.Y.Z` | `oci://ghcr.io/<owner>/charts/cube-stack-ha:X.Y.Z` |
| `chart-vX.Y.Z` (legacy) | same as `cube-stack-v*`, kept for back-compat |

## Picking a chart

You want **`cube-stack`** if:

- You run vanilla Cube.js and a single Cube Store router is acceptable
  for your availability target.
- Your metadata workload is light enough that the router can reschedule
  on pod failure within your downtime budget.

You want **`cube-stack-ha`** if:

- You want to survive a single Cube Store router pod loss with sub-10s
  automatic failover.
- You're OK running the agriev/cube fork's image (rebased quarterly
  on upstream Cube; HA changes are additive — `CUBESTORE_HA_MODE=off`
  reverts to upstream behavior).

Both charts share the same Cube API, refresh worker, datasource wiring,
schema-delivery options, and remote-storage backends. They differ only
in the Cube Store router's replication story.

## Per-chart upgrade notes

- [`cube-stack@1.0.0 → 1.1.0`](../charts/cube-stack/UPGRADE.md)
- [`cube-stack-ha@1.0.0` (first release)](../charts/cube-stack-ha/UPGRADE.md)
