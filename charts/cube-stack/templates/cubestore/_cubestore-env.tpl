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
