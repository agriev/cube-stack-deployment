{{/*
Common Cube Store env vars for both router and workers.
Includes: log level, server name, ports, remote storage backend (S3/GCS/MinIO/PVC).
*/}}
{{- define "cubeStack.cubestoreEnv" -}}
- name: CUBESTORE_LOG_LEVEL
  value: {{ .Values.cubestore.logLevel | quote }}
- name: CUBESTORE_NO_UPLOAD
  value: "false"
{{- if .Values.cubestore.queryTimeout }}
- name: CUBESTORE_QUERY_TIMEOUT
  value: {{ .Values.cubestore.queryTimeout | quote }}
{{- end }}
{{- if .Values.cubestore.jobRunners }}
- name: CUBESTORE_JOB_RUNNERS
  value: {{ .Values.cubestore.jobRunners | quote }}
{{- end }}
{{- if .Values.cubestore.awsCredsRefreshEveryMins }}
- name: CUBESTORE_AWS_CREDS_REFRESH_EVERY_MINS
  value: {{ .Values.cubestore.awsCredsRefreshEveryMins | quote }}
{{- end }}
{{- if gt (.Values.cubestore.selectWorkers | int) 0 }}
- name: CUBESTORE_SELECT_WORKERS
  value: {{ .Values.cubestore.selectWorkers | quote }}
{{- end }}
{{- with .Values.cubestore.remoteStorage }}
{{- if eq .type "s3" }}
- name: CUBESTORE_S3_BUCKET
  value: {{ .s3.bucket | quote }}
- name: CUBESTORE_S3_REGION
  value: {{ .s3.region | quote }}
{{- if .s3.subPath }}
- name: CUBESTORE_S3_SUB_PATH
  value: {{ .s3.subPath | quote }}
{{- end }}
{{- if .s3.existingSecret }}
- name: CUBESTORE_AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .s3.existingSecret | quote }}
      key: {{ .s3.accessKeyKey | quote }}
- name: CUBESTORE_AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .s3.existingSecret | quote }}
      key: {{ .s3.secretKeyKey | quote }}
{{- else if .s3.accessKey }}
- name: CUBESTORE_AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: cubestore-s3-access-key
- name: CUBESTORE_AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: cubestore-s3-secret-key
{{- end }}
{{- end }}
{{- if eq .type "gcs" }}
- name: CUBESTORE_GCS_BUCKET
  value: {{ .gcs.bucket | quote }}
{{- if .gcs.subPath }}
- name: CUBESTORE_GCS_SUB_PATH
  value: {{ .gcs.subPath | quote }}
{{- end }}
- name: GOOGLE_APPLICATION_CREDENTIALS
  value: /etc/cubestore/gcs/credentials.json
{{- end }}
{{- if eq .type "minio" }}
- name: CUBESTORE_MINIO_BUCKET
  value: {{ .minio.bucket | quote }}
- name: CUBESTORE_MINIO_SERVER_ENDPOINT
  value: {{ .minio.endpoint | quote }}
- name: CUBESTORE_MINIO_REGION
  value: {{ .minio.region | quote }}
{{- if .minio.subPath }}
- name: CUBESTORE_MINIO_SUB_PATH
  value: {{ .minio.subPath | quote }}
{{- end }}
{{- if .minio.existingSecret }}
- name: CUBESTORE_MINIO_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .minio.existingSecret | quote }}
      key: {{ .minio.accessKeyKey | quote }}
- name: CUBESTORE_MINIO_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .minio.existingSecret | quote }}
      key: {{ .minio.secretKeyKey | quote }}
{{- else if .minio.accessKey }}
- name: CUBESTORE_MINIO_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: cubestore-minio-access-key
- name: CUBESTORE_MINIO_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: cubestore-minio-secret-key
{{- end }}
{{- end }}
{{- end }}
{{- if not (include "cubeStack.cubestore.hasCloudBucket" .) }}
- name: CUBESTORE_REMOTE_DIR
  value: {{ .Values.cubestore.remoteStorage.sharedPvc.mountPath | quote }}
{{- end }}
- name: CUBESTORE_DATA_DIR
  value: {{ .Values.cubestore.router.persistence.mountPath | quote }}
{{- with .Values.cubestore.extraEnv }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/*
Workers list (FQDN form) emitted as CUBESTORE_WORKERS env var.
*/}}
{{- define "cubeStack.cubestore.workersEnv" -}}
{{- $count := .Values.cubestore.workers.replicas | int -}}
{{- if gt $count 0 }}
- name: CUBESTORE_WORKERS
  value: {{ include "cubeStack.cubestore.workerAddrs" . | quote }}
{{- end }}
{{- end -}}

{{/*
HA fork — Raft env vars emitted on the router pod when ha.enabled.

CUBESTORE_NODE_ID is derived from the StatefulSet pod ordinal. We
read POD_NAME via the downward API and extract the trailing integer
in a sh wrapper around the cubestored binary (see the StatefulSet's
command: block). Pod ordinal `cubestore-router-0` → NODE_ID=1, `-1`
→ 2, `-2` → 3.

CUBESTORE_RAFT_PEERS is a static list emitted at template-render
time from `replicas` and the headless service DNS. Every replica
gets the SAME list, including itself — that's the contract the
binary boot path checks.
*/}}
{{- define "cubeStack.cubestore.haEnv" -}}
{{- if .Values.cubestore.ha.enabled -}}
- name: CUBESTORE_HA_MODE
  value: "raft"
- name: CUBESTORE_RAFT_PORT
  value: {{ .Values.cubestore.ha.raftPort | quote }}
- name: CUBESTORE_RAFT_PEERS
  value: {{ include "cubeStack.cubestore.raftPeers" . | quote }}
{{- if .Values.cubestore.ha.raftLogDir }}
- name: CUBESTORE_HA_RAFT_LOG_DIR
  value: {{ .Values.cubestore.ha.raftLogDir | quote }}
{{- end }}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
{{- end -}}
{{- end -}}

{{/*
Comma-separated raft peer list: `<id>@<podname>.<svc>:<port>`.
Pod ordinal i (0-indexed) → raft id (i+1). Reserved 0 is raft-rs's
"no peer" sentinel; the parser in agriev/cube refuses it explicitly.

The DNS name is resolved via the StatefulSet's serviceName — the
main router service. Kubernetes emits per-pod A records under
`<podname>.<serviceName>.<ns>.svc.cluster.local` for any service
referenced as a StatefulSet's serviceName, even when it's
ClusterIP rather than headless. This avoids the need for a
separate headless service just for raft peer DNS.
*/}}
{{- define "cubeStack.cubestore.raftPeers" -}}
{{- $base := include "cubeStack.cubestore.router.fullname" . -}}
{{- $port := .Values.cubestore.ha.raftPort | int -}}
{{- $count := .Values.cubestore.router.replicas | int -}}
{{- $list := list -}}
{{- range $i := until $count -}}
{{- $id := add $i 1 -}}
{{- $list = append $list (printf "%d@%s-%d.%s:%d" $id $base $i $base $port) -}}
{{- end -}}
{{- join "," $list -}}
{{- end -}}
