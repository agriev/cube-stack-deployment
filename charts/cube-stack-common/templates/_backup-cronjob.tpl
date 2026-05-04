{{/*
Cube Store backup CronJob — exec's into a router pod, tars the
metastore data dir, pushes the archive to S3.

Topology:
  - vanilla cube-stack: backs up router-0 (the only router).
  - cube-stack-ha: backs up router-0 (same data as leader; Raft has
    replicated all writes to all 3 pods. Router-0 is a stable target;
    a leader-detection pass would be more expensive than the
    consistency win for an offline backup.).

The backup container needs `pods/exec` RBAC in the chart's namespace
and AWS credentials (CUBESTORE_AWS_*) — both wired via the
ServiceAccount + Secret references in backup-rbac.yaml.

Usage from a concrete chart:

  {{- include "cubeStack.cubestore.backupCronJob" . }}
*/}}
{{- define "cubeStack.cubestore.backupCronJob" -}}
{{- if .Values.cubestore.backup.enabled }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ printf "%s-backup" (include "cubeStack.cubestore.router.fullname" .) }}
  namespace: {{ .Release.Namespace }}
  labels: {{- include "cubeStack.componentLabels" (dict "ctx" . "component" "cubestore-backup") | nindent 4 }}
  {{- include "cubeStack.maybeAnnotations" . | nindent 2 }}
spec:
  schedule: {{ .Values.cubestore.backup.schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 7
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        metadata:
          labels: {{- include "cubeStack.componentSelectorLabels" (dict "ctx" . "component" "cubestore-backup") | nindent 12 }}
        spec:
          serviceAccountName: {{ include "cubeStack.cubestore.router.fullname" . }}-backup
          restartPolicy: OnFailure
          {{- with .Values.global.imagePullSecrets }}
          imagePullSecrets: {{- toYaml . | nindent 12 }}
          {{- end }}
          securityContext: {{- toYaml .Values.podSecurityContext | nindent 12 }}
          containers:
            - name: backup
              image: {{ .Values.cubestore.backup.image.repository }}:{{ .Values.cubestore.backup.image.tag }}
              imagePullPolicy: {{ .Values.cubestore.backup.image.pullPolicy }}
              securityContext: {{- toYaml .Values.containerSecurityContext | nindent 16 }}
              env:
                - name: NS
                  value: {{ .Release.Namespace }}
                - name: POD
                  value: {{ printf "%s-0" (include "cubeStack.cubestore.router.fullname" .) }}
                - name: DATA_DIR
                  value: {{ .Values.cubestore.router.persistence.mountPath | quote }}
                - name: DESTINATION
                  value: {{ .Values.cubestore.backup.destination | quote }}
                - name: KUBECTL_VERSION
                  value: {{ .Values.cubestore.backup.kubectlVersion | quote }}
                {{- /* Reuse the same AWS creds Cube Store itself uses. */ -}}
                {{- with .Values.cubestore.remoteStorage.s3 }}
                {{- if .existingSecret }}
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: {{ .existingSecret | quote }}
                      key: {{ .accessKeyKey | quote }}
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: {{ .existingSecret | quote }}
                      key: {{ .secretKeyKey | quote }}
                {{- end }}
                - name: AWS_DEFAULT_REGION
                  value: {{ .region | quote }}
                {{- end }}
              command:
                - /bin/sh
                - -c
                - |
                  set -eu
                  # The amazon/aws-cli image doesn't ship kubectl. Pull a
                  # static binary on each run. For prod, bake your own
                  # image — see docs/RESTORE.md.
                  curl -fsSL -o /tmp/kubectl \
                    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
                  chmod +x /tmp/kubectl

                  TS=$(date -u +%Y%m%dT%H%M%SZ)
                  ARCHIVE="$(basename ${DESTINATION})-${TS}.tar.gz"
                  KEY="${DESTINATION%/}/${ARCHIVE}"

                  echo "==> backup ${POD}:${DATA_DIR} → ${KEY}"
                  /tmp/kubectl -n "$NS" exec "$POD" -- \
                      tar -cz -C "$DATA_DIR" . \
                    | aws s3 cp - "$KEY" \
                        --storage-class STANDARD_IA \
                        --metadata "release={{ .Release.Name }},chart={{ .Chart.Name }},chart_version={{ .Chart.Version }}"

                  echo "==> success: $KEY"
              resources: {{- toYaml .Values.cubestore.backup.resources | nindent 16 }}
{{- end }}
{{- end -}}

{{- define "cubeStack.cubestore.backupRBAC" -}}
{{- if .Values.cubestore.backup.enabled }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ printf "%s-backup" (include "cubeStack.cubestore.router.fullname" .) }}
  namespace: {{ .Release.Namespace }}
  labels: {{- include "cubeStack.componentLabels" (dict "ctx" . "component" "cubestore-backup") | nindent 4 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ printf "%s-backup" (include "cubeStack.cubestore.router.fullname" .) }}
  namespace: {{ .Release.Namespace }}
  labels: {{- include "cubeStack.componentLabels" (dict "ctx" . "component" "cubestore-backup") | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [pods/exec]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ printf "%s-backup" (include "cubeStack.cubestore.router.fullname" .) }}
  namespace: {{ .Release.Namespace }}
  labels: {{- include "cubeStack.componentLabels" (dict "ctx" . "component" "cubestore-backup") | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ printf "%s-backup" (include "cubeStack.cubestore.router.fullname" .) }}
    namespace: {{ .Release.Namespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ printf "%s-backup" (include "cubeStack.cubestore.router.fullname" .) }}
{{- end }}
{{- end -}}
