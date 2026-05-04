# cube-stack — upgrade guide

## 1.0.0 → 1.1.0

### What changed

1. **The `cubestore.ha.*` values block was removed** from this chart.
   HA was always opt-in (`enabled: false` default in 1.0.0), so users
   running the vanilla single-router setup are not affected.

2. **The `_helpers.tpl` helpers moved to a new
   [`cube-stack-common`](../cube-stack-common) library chart**, listed
   as a `dependencies:` entry in `Chart.yaml`. `helm dependency update
   charts/cube-stack` (or `make deps`) pulls it in. There's no behavior
   change — the helpers render the same names and labels as before.

3. **Validation: `cubestore.router.replicas > 1` is now rejected.**
   Cube Store Community Edition can't replicate router metadata, so a
   2- or 3-router setup with the upstream image silently runs as N
   independent stores that drift apart on writes. Use the new
   [`cube-stack-ha`](../cube-stack-ha) chart for a real 3-router Raft
   cluster.

4. **Maintainer entry rewritten** from `Platform Team` (not a real
   GitHub user) to `agriev`. Cosmetic; affects only `helm show chart`
   output.

5. **Release tags**: `cube-stack-vX.Y.Z` is now the canonical tag
   pattern. The legacy `chart-vX.Y.Z` pattern still publishes this
   chart for back-compat.

### Migration steps

For users on `cube-stack@1.0.0` with `cubestore.ha.enabled: false`
(the default):

```bash
helm dependency update charts/cube-stack    # pulls cube-stack-common
helm upgrade cube charts/cube-stack \
  -f your-values.yaml \
  -n cube --wait
```

For users on `cube-stack@1.0.0` with `cubestore.ha.enabled: true`
(only possible if you were on the [Unreleased] HA work in main —
no released versions had this flag): switch to `cube-stack-ha`. See
its [UPGRADE.md](../cube-stack-ha/UPGRADE.md) for the migration path.

### Breaking-flag inventory

| Flag | 1.0.0 | 1.1.0 | Action |
|---|---|---|---|
| `cubestore.ha.*` | present (off by default) | **removed** | switch to `cube-stack-ha` if you were using HA |
| `cubestore.router.replicas` | any int | must be `1` | use `cube-stack-ha` for >1 |
| `dependencies` | redis only | + `cube-stack-common` | run `helm dependency update` |

Nothing else has changed shape. Resource manifests rendered with the
default `values-prod.yaml` / `values-dev.yaml` / `values-quickstart.yaml`
overlays are byte-identical between 1.0.0 and 1.1.0 except for the
removal of HA-specific resources (which never rendered when `ha.enabled:
false`).
