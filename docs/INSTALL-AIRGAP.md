# Air-gapped install — runbook

This procedure deploys the cube-stack (or cube-stack-ha) chart into a
Kubernetes cluster that has no outbound internet access. It covers
mirroring images, mirroring the chart, offline cosign verification,
and the install command.

> **Verify cosign before mirroring.** Always run `cosign verify-blob`
> against the signed blob before pushing the chart into your private
> registry. After mirroring, the upstream signature is no longer
> reachable; if you mirror a tampered blob you've sealed the breach
> in.

## 0. Tools you'll need on the bastion

The bastion needs internet access. These run on the bastion, then
artifacts are shipped to the air-gapped network.

| Tool         | Purpose                                              |
| ------------ | ---------------------------------------------------- |
| `helm` 3.14+ | Pull chart from `oci://` and re-package              |
| `cosign` 2+  | Verify blob signature                                |
| `skopeo`     | Mirror container images between registries          |
| `crane`      | (alternative to skopeo) inspect/pin digests          |

## 1. Pull the chart and verify signature

```bash
# 1a. Get the chart bundle, the blob signature, and the cert
TAG=v1.1.0
gh release download cube-stack-${TAG} \
  --repo agriev/cube-stack-deployment \
  --pattern '*.tgz*' --pattern '*.cdx.json' \
  --dir ./_release

ls _release/
# cube-stack-1.1.0.tgz
# cube-stack-1.1.0.tgz.sig
# cube-stack-1.1.0.tgz.cert
# cube-stack-1.1.0.cdx.json

# 1b. Verify the blob. Identity must match the release workflow.
cosign verify-blob \
  --signature   _release/cube-stack-1.1.0.tgz.sig \
  --certificate _release/cube-stack-1.1.0.tgz.cert \
  --certificate-identity-regexp \
    'https://github.com/agriev/cube-stack-deployment/.github/workflows/release.yaml@refs/tags/cube-stack-v.*' \
  --certificate-oidc-issuer-regexp \
    'https://token\.actions\.githubusercontent\.com' \
  _release/cube-stack-1.1.0.tgz
```

## 2. Mirror images

Read the SBOM (`*.cdx.json`) to enumerate every image the chart can
pull (cube, cubestored, redis subchart, statsd-exporter, curl,
busybox, statsd, aws-cli for backup, ...). Then mirror each:

```bash
SRC_REG=ghcr.io                 # public source
DST_REG=registry.internal.lan   # your private mirror

# Example for the cube image
SRC=${SRC_REG}/agriev/cube-stack-deployment/cube:v1.6.41
DST=${DST_REG}/agriev/cube-stack-deployment/cube:v1.6.41

skopeo copy --multi-arch all docker://${SRC} docker://${DST}
```

Repeat for every image in the SBOM. Bitnami Redis subchart (if
enabled) must also be mirrored — the chart pulls it from
`registry-1.docker.io/bitnamicharts/redis`.

## 3. Mirror the chart to your private OCI registry

```bash
# Push to your private OCI repo. The chart bundle is the .tgz on disk.
helm registry login ${DST_REG} -u <you>
helm push _release/cube-stack-1.1.0.tgz oci://${DST_REG}/charts
```

If your operators want OCI-signed (not just blob-signed) charts on the
mirror, push the cosign signature artifact too — `cosign copy
ghcr.io/.../charts/cube-stack:1.1.0
${DST_REG}/charts/cube-stack:1.1.0` does this.

## 4. Install on the air-gapped cluster

```bash
helm install cube oci://${DST_REG}/charts/cube-stack \
  --version 1.1.0 \
  -n cube --create-namespace \
  -f charts/cube-stack/values.yaml \
  -f examples/values-onprem-pki.yaml \
  -f examples/values-onprem-minio.yaml \
  --set image.registry=${DST_REG} \
  --set cubestoreImage.registry=${DST_REG}
```

`image.registry` and `cubestoreImage.registry` flip every chart-managed
image to your mirror. Bitnami subchart (Redis) needs its own override
on the subchart prefix — `--set redis.image.registry=${DST_REG}` etc.

## 5. Re-verify after install

```bash
helm get values cube -n cube
helm test cube -n cube
kubectl -n cube describe pods | grep -E 'Image:|FailedScheduling'
```

## Hot-fix loop

When you mirror a new chart version:

1. Repeat steps 1–3.
2. `helm upgrade` with the new chart version.
3. Keep the previous chart `.tgz` + signatures in escrow for rollback
   (your `helm rollback` won't work without the chart still locally
   accessible).

## Known gotchas

- **PR-O2's NetworkPolicy lockdown** (`networkPolicy.allowAllEgress:
  false`) blocks egress to anything not in `extraEgress`. Make sure
  your private registry namespace is allowed if your image puller
  uses `imagePullSecrets` from a different node.
- **Cosign keyless verification** requires the cluster have access to
  the Sigstore Rekor / Fulcio API. In a fully air-gapped environment
  this won't reach. The blob verification on the bastion is the trust
  anchor; the cluster never re-verifies. If your policy needs the
  cluster to verify too, deploy a private Sigstore stack (out of
  scope here).
- **Bitnami subchart**. `helm dependency update` on a private mirror
  requires `repository: oci://${DST_REG}/...` in `Chart.yaml`. The
  chart ships with the upstream Bitnami URL hard-coded in
  `Chart.lock`; either pre-populate the chart's `charts/` dir with
  the mirrored Redis tarball or fork and pin.
