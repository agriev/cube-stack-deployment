#!/usr/bin/env bash
#
# setup-minio.sh — bring up an in-cluster MinIO + create the cubestore
# bucket. Required pre-flight for `make ha-deploy` since the chart's
# `cubestore.remoteStorage.type=minio` points at `minio.cube-ha.svc:9000`.
#
# Idempotent: re-applying is safe; `mc mb --ignore-existing` swallows
# the "bucket already exists" error from a prior run.

set -euo pipefail

NS=${NS:-cube-ha}
BUCKET=${BUCKET:-cubestore}
MANIFEST_DIR="$(dirname "$0")"

echo "==> Applying MinIO manifest in namespace ${NS}..."
kubectl apply -f "${MANIFEST_DIR}/minio.yaml"

echo "==> Waiting for MinIO pod Ready..."
kubectl -n "$NS" wait --for=condition=Ready pod/minio --timeout=120s

echo "==> Creating bucket ${BUCKET}..."
# Use the minio pod itself for `mc` so we don't depend on host having
# mc installed. The image ships with `mc` at /usr/bin/mc.
kubectl -n "$NS" exec minio -- /bin/sh -c "
  set -e
  mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null
  mc mb --ignore-existing local/${BUCKET}
  mc ls local/
"
echo "==> MinIO ready at http://minio.${NS}.svc:9000  bucket=${BUCKET}"
