# Restoring a Cube Store metastore from backup

Companion to the backup CronJob shipped by both `cube-stack` and
`cube-stack-ha` (template:
[cube-stack-common/templates/_backup-cronjob.tpl](../charts/cube-stack-common/templates/_backup-cronjob.tpl),
gated on `cubestore.backup.enabled`).

## What's in the backup

A `.tar.gz` archive of the entire `cubestore.router.persistence.mountPath`
directory (`/cube/.cubestore/data` by default), captured from
**router-0** of a running release. For HA this means: the RocksDB
metastore + the local Raft log + Raft hardstate + ConfState. For
vanilla: just the metastore.

S3 object name: `<destination>/<chart>-<UTC-timestamp>.tar.gz`,
e.g. `s3://my-cube-backups/cube-stack-ha/cube-stack-ha-20260504T020000Z.tar.gz`.

## When to restore

The metastore is the source of truth for:

- The list of pre-aggregations and their partitioning.
- The chunk-to-worker mapping (which worker holds what data).
- The job queue (refresh-worker schedules).

Pre-aggregation **data** (the parquet files) lives in remote storage
(S3/GCS/MinIO/shared-PVC) and is recoverable from there. The
metastore restore brings back the **catalog**.

Restore when:

- A `make ha-reset` was the only path out of an election storm.
- Storage corruption broke the RocksDB on every router.
- You're cloning a release into a new cluster.

## Procedure (vanilla cube-stack)

```bash
NS=cube
REL=cube
ARCHIVE=s3://my-cube-backups/cube-stack/cube-stack-20260504T020000Z.tar.gz

# 1. Scale router to 0 so nothing is writing to the PVC
kubectl -n $NS scale sts/${REL}-cube-stack-cubestore-router --replicas=0
kubectl -n $NS wait --for=delete pod -l app.kubernetes.io/component=cubestore-router --timeout=120s

# 2. Provision a temp pod that mounts the same PVC
PVC=$(kubectl -n $NS get pvc -l app.kubernetes.io/component=cubestore-router \
  -o jsonpath='{.items[0].metadata.name}')

cat <<EOF | kubectl -n $NS apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cubestore-restore
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: amazon/aws-cli:latest
      command: ['sleep', '3600']
      volumeMounts:
        - name: data
          mountPath: /restore
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC}
EOF

kubectl -n $NS wait --for=condition=Ready pod/cubestore-restore --timeout=120s

# 3. Wipe the PVC and untar the backup
kubectl -n $NS exec cubestore-restore -- /bin/sh -c '
  rm -rf /restore/*
  aws s3 cp '"$ARCHIVE"' - | tar -xz -C /restore
  ls -la /restore
'

# 4. Clean up the temp pod
kubectl -n $NS delete pod cubestore-restore

# 5. Scale router back up
kubectl -n $NS scale sts/${REL}-cube-stack-cubestore-router --replicas=1
kubectl -n $NS wait --for=condition=ready pod -l app.kubernetes.io/component=cubestore-router --timeout=120s

# 6. Verify
kubectl -n $NS port-forward svc/${REL}-cube-stack-cubestore-router 3030 &
curl -s localhost:3030/livez
```

## Procedure (cube-stack-ha)

The HA case is trickier: every router has its own PVC, and the Raft
log on each PVC contains its node-specific state (votedFor,
appliedIndex, ConfState peer list). Restoring the same archive to all
3 PVCs gives you a cluster that thinks it's 3 copies of the same node
— Raft refuses to elect.

The supported restore path:

1. Restore the archive to **router-0's PVC only**.
2. Scale to 1 replica. Router-0 boots cold as a single-node Raft
   cluster (peers list still has 3 entries, but the other two pods
   don't exist; raft-rs handles this by tolerating the unreachable
   peers).
3. Once router-0 is leader, scale back up to 3. Routers 1 and 2 boot
   with empty PVCs and pull a Raft snapshot from router-0
   (M5-complete: peer-to-peer snapshot install).

```bash
NS=cube-ha
REL=cube-ha
ARCHIVE=s3://my-cube-backups/cube-stack-ha/cube-stack-ha-20260504T020000Z.tar.gz

# 1. Tear everything down (the StatefulSet, its PVCs, the Raft state)
helm uninstall $REL -n $NS
kubectl -n $NS delete pvc -l app.kubernetes.io/component=cubestore-router

# 2. Re-install with router replicas=1 so only router-0's PVC is created
helm install $REL charts/cube-stack-ha \
  -f charts/cube-stack-ha/values.yaml \
  --set cubestore.router.replicas=1 \
  --namespace $NS --create-namespace --wait --timeout 5m

# 3. Restore archive into router-0's PVC (pod is running; `kubectl cp` style)
kubectl -n $NS exec ${REL}-cube-stack-ha-cubestore-router-0 -- /bin/sh -c '
  # router process is using the data dir; better to do this BEFORE pod
  # is fully up. Easier: scale to 0, mount-and-restore via a temp pod
  # like the vanilla case.
  echo "scale to 0 first; see vanilla procedure"; exit 1
'

# (in practice, follow the vanilla procedure above to mount router-0's
# PVC into a temp pod and untar there. Then continue:)

# 4. Scale back up
helm upgrade $REL charts/cube-stack-ha \
  -f charts/cube-stack-ha/values.yaml \
  --set cubestore.router.replicas=3 \
  --namespace $NS --wait --timeout 5m

# 5. Verify the cluster reformed and elected a leader from the
#    restored data
make ha-verify
```

## Why aren't all 3 PVCs restored?

The Raft log on each PVC contains node-specific state. Restoring the
same archive to all 3 makes them identical — including the persisted
`votedFor` of node-1. On boot all three nodes claim to have voted for
the same candidate in the same term and the cluster won't progress.

Restoring to router-0 only and letting routers 1+2 catch up via Raft's
snapshot-install protocol is the supported path. The agriev/cube
fork's M5.6.x work made this reliable.
