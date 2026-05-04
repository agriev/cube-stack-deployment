{{/*
Common helpers for the cube-stack chart.

Naming convention:
  {{ include "cubeStack.fullname" . }}              -> "<release>-cube-stack"
  {{ include "cubeStack.api.fullname" . }}          -> "<release>-cube-stack-api"
  {{ include "cubeStack.refreshWorker.fullname" }}  -> "<release>-cube-stack-refresh-worker"
  {{ include "cubeStack.cubestore.router.fullname"} -> "<release>-cube-stack-cubestore-router"
  {{ include "cubeStack.cubestore.workers.fullname" -> "<release>-cube-stack-cubestore-workers"
  {{ include "cubeStack.cubestore.workers.headless"  -> "<release>-cube-stack-cubestore-workers-headless"
*/}}

{{- define "cubeStack.name" -}}
{{- default .Chart.Name .Values.global.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cubeStack.fullname" -}}
{{- if .Values.global.fullnameOverride -}}
{{- .Values.global.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.global.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "cubeStack.api.fullname" -}}
{{- printf "%s-api" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cubeStack.refreshWorker.fullname" -}}
{{- printf "%s-refresh-worker" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cubeStack.cubestore.router.fullname" -}}
{{- printf "%s-cubestore-router" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cubeStack.cubestore.workers.fullname" -}}
{{- printf "%s-cubestore-workers" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cubeStack.cubestore.workers.headless" -}}
{{- printf "%s-cubestore-workers-headless" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "cubeStack.secrets.fullname" -}}
{{- printf "%s-secrets" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cubeStack.schema.configmap.fullname" -}}
{{- if .Values.schema.configMap.name -}}
{{- .Values.schema.configMap.name -}}
{{- else -}}
{{- printf "%s-schema" (include "cubeStack.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Image tag resolver — image.tag > global.imageTag > .Chart.AppVersion
*/}}
{{- define "cubeStack.image" -}}
{{- $tag := default .Values.global.imageTag .Values.image.tag -}}
{{- $tag = default .Chart.AppVersion $tag -}}
{{- if not (hasPrefix "v" $tag) -}}
{{- $tag = printf "v%s" $tag -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{- define "cubeStack.cubestoreImage" -}}
{{- $tag := default .Values.global.imageTag .Values.cubestoreImage.tag -}}
{{- $tag = default .Chart.AppVersion $tag -}}
{{- if not (hasPrefix "v" $tag) -}}
{{- $tag = printf "v%s" $tag -}}
{{- end -}}
{{- with .Values.cubestoreImage.archSuffix }}{{- $tag = printf "%s%s" $tag . -}}{{- end -}}
{{- printf "%s:%s" .Values.cubestoreImage.repository $tag -}}
{{- end -}}

{{/*
Standard labels (https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)
*/}}
{{- define "cubeStack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "cubeStack.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cube-stack
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "cubeStack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cubeStack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Render `annotations:` block only when global.commonAnnotations is non-empty.
Usage:
  metadata:
    name: ...
    {{- include "cubeStack.maybeAnnotations" . | nindent 2 }}
*/}}
{{- define "cubeStack.maybeAnnotations" -}}
{{- with .Values.global.commonAnnotations -}}
annotations:
{{ toYaml . | indent 2 }}
{{- end -}}
{{- end -}}

{{- define "cubeStack.annotations" -}}
{{- with .Values.global.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Component-specific selector labels — adds app.kubernetes.io/component
Usage: {{ include "cubeStack.componentSelectorLabels" (dict "ctx" . "component" "api") }}
*/}}
{{- define "cubeStack.componentSelectorLabels" -}}
{{ include "cubeStack.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "cubeStack.componentLabels" -}}
{{ include "cubeStack.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Service account name resolvers
*/}}
{{- define "cubeStack.api.serviceAccountName" -}}
{{- if .Values.api.serviceAccount.create -}}
{{- default (include "cubeStack.api.fullname" .) .Values.api.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.api.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "cubeStack.refreshWorker.serviceAccountName" -}}
{{- if .Values.refreshWorker.serviceAccount.create -}}
{{- default (include "cubeStack.refreshWorker.fullname" .) .Values.refreshWorker.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.refreshWorker.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "cubeStack.cubestore.router.serviceAccountName" -}}
{{- if .Values.cubestore.router.serviceAccount.create -}}
{{- default (include "cubeStack.cubestore.router.fullname" .) .Values.cubestore.router.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.cubestore.router.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "cubeStack.cubestore.workers.serviceAccountName" -}}
{{- if .Values.cubestore.workers.serviceAccount.create -}}
{{- default (include "cubeStack.cubestore.workers.fullname" .) .Values.cubestore.workers.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.cubestore.workers.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Cube Store router host:port (used by the Cube API to reach the router)
*/}}
{{- define "cubeStack.cubestore.routerHost" -}}
{{- include "cubeStack.cubestore.router.fullname" . -}}
{{- end -}}

{{/*
Cube Store worker addresses — comma separated list of POD-FQDN:PORT
*/}}
{{- define "cubeStack.cubestore.workerAddrs" -}}
{{- $headless := include "cubeStack.cubestore.workers.headless" . -}}
{{- $base := include "cubeStack.cubestore.workers.fullname" . -}}
{{- $port := .Values.cubestore.workerPort | int -}}
{{- $count := .Values.cubestore.workers.replicas | int -}}
{{- $list := list -}}
{{- range $i := until $count -}}
{{- $list = append $list (printf "%s-%d.%s:%d" $base $i $headless $port) -}}
{{- end -}}
{{- join "," $list -}}
{{- end -}}

{{/*
Topology spread defaults — emits a `topologySpreadConstraints:` block when
the user did not override and global.topologySpread is non-empty.
Usage: {{ include "cubeStack.topologySpread" (dict "ctx" . "component" "api" "user" .Values.api.topologySpreadConstraints) }}
*/}}
{{- define "cubeStack.topologySpread" -}}
{{- if .user -}}
{{ toYaml .user }}
{{- else if .ctx.Values.global.topologySpread -}}
{{- $whenUnsatisfiable := "ScheduleAnyway" -}}
{{- if eq .ctx.Values.global.topologySpread "hard" -}}
{{- $whenUnsatisfiable = "DoNotSchedule" -}}
{{- end }}
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: {{ $whenUnsatisfiable }}
  labelSelector:
    matchLabels:
      {{ include "cubeStack.componentSelectorLabels" (dict "ctx" .ctx "component" .component) | nindent 6 }}
{{- end -}}
{{- end -}}

{{/*
Render extraEnvFrom — accepts a list of envFrom entries
*/}}
{{- define "cubeStack.extraEnvFrom" -}}
{{- $merged := list -}}
{{- range .global -}}{{- $merged = append $merged . -}}{{- end -}}
{{- range .component -}}{{- $merged = append $merged . -}}{{- end -}}
{{- if $merged }}
envFrom:
{{- toYaml $merged | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Render the standard env vars block applied to every Cube Pod (API + worker).
Includes Cube core, Cube Store wiring, Redis (if used) and data sources.
*/}}
{{- define "cubeStack.cubeEnv" -}}
{{ include "cubeStack.cubeEnv.core" . }}
{{ include "cubeStack.cubeEnv.cubestore" . }}
{{ include "cubeStack.cubeEnv.redis" . }}
{{ include "cubeStack.cubeEnv.jwt" . }}
{{ include "cubeStack.cubeEnv.datasources" . }}
{{ include "cubeStack.cubeEnv.s3" . }}
{{- end -}}

{{- define "cubeStack.cubeEnv.core" -}}
- name: NODE_ENV
  value: production
{{- if .Values.quickstart.enabled }}
- name: CUBEJS_DEV_MODE
  value: "true"
{{- else }}
- name: CUBEJS_DEV_MODE
  value: {{ .Values.cube.devMode | quote }}
{{- end }}
- name: CUBEJS_LOG_LEVEL
  value: {{ .Values.cube.logLevel | quote }}
- name: CUBEJS_TELEMETRY
  value: {{ .Values.cube.telemetry | quote }}
- name: CUBEJS_API_PORT
  value: {{ .Values.cube.apiPort | quote }}
{{- if gt (.Values.cube.pgSqlPort | int) 0 }}
- name: CUBEJS_PG_SQL_PORT
  value: {{ .Values.cube.pgSqlPort | quote }}
{{- end }}
{{- if gt (.Values.cube.sqlPort | int) 0 }}
- name: CUBEJS_SQL_PORT
  value: {{ .Values.cube.sqlPort | quote }}
{{- end }}
{{- if .Values.cube.webSockets }}
- name: CUBEJS_WEB_SOCKETS
  value: "true"
{{- end }}
- name: CUBEJS_CACHE_AND_QUEUE_DRIVER
  value: {{ .Values.cube.cacheAndQueueDriver | quote }}
- name: CUBEJS_SCHEMA_PATH
  value: {{ .Values.cube.schemaPath | quote }}
- name: CUBEJS_EXTERNAL_DEFAULT
  value: {{ .Values.cube.externalDefault | quote }}
- name: CUBEJS_ROLLUP_ONLY
  value: {{ .Values.cube.rollupOnlyMode | quote }}
{{- if .Values.cube.preAggregationsSchema }}
- name: CUBEJS_PRE_AGGREGATIONS_SCHEMA
  value: {{ .Values.cube.preAggregationsSchema | quote }}
{{- end }}
{{- if .Values.cube.cors }}
- name: CUBEJS_CORS_ORIGIN
  value: {{ .Values.cube.cors | quote }}
{{- end }}
{{- if .Values.cube.defaultApiScopes }}
- name: CUBEJS_DEFAULT_API_SCOPES
  value: {{ .Values.cube.defaultApiScopes | quote }}
{{- end }}
{{- if .Values.cube.concurrency }}
- name: CUBEJS_CONCURRENCY
  value: {{ .Values.cube.concurrency | quote }}
{{- end }}
{{- if .Values.cube.maxSessions }}
- name: CUBEJS_MAX_SESSIONS
  value: {{ .Values.cube.maxSessions | quote }}
{{- end }}
{{- if .Values.cube.dbQueryTimeout }}
- name: CUBEJS_DB_QUERY_TIMEOUT
  value: {{ .Values.cube.dbQueryTimeout | quote }}
{{- end }}
{{- if .Values.cube.dbQueryLimit }}
- name: CUBEJS_DB_QUERY_LIMIT
  value: {{ .Values.cube.dbQueryLimit | quote }}
{{- end }}
{{- if .Values.cube.schedulerInterval }}
- name: CUBEJS_SCHEDULED_REFRESH_TIMER
  value: {{ .Values.cube.schedulerInterval | quote }}
{{- end }}
{{- if .Values.cube.apiSecretFromSecret.name }}
- name: CUBEJS_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cube.apiSecretFromSecret.name | quote }}
      key: {{ .Values.cube.apiSecretFromSecret.key | quote }}
{{- else }}
- name: CUBEJS_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" . }}
      key: cube-api-secret
{{- end }}
{{- if .Values.cube.sqlAuth.existingSecret }}
- name: CUBEJS_SQL_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cube.sqlAuth.existingSecret | quote }}
      key: username
- name: CUBEJS_SQL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cube.sqlAuth.existingSecret | quote }}
      key: password
{{- else if .Values.cube.sqlAuth.user }}
- name: CUBEJS_SQL_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" . }}
      key: cube-sql-user
- name: CUBEJS_SQL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" . }}
      key: cube-sql-password
{{- end }}
{{- end -}}

{{- define "cubeStack.cubeEnv.cubestore" -}}
{{- if .Values.cubestore.enabled }}
- name: CUBEJS_CUBESTORE_HOST
  value: {{ include "cubeStack.cubestore.routerHost" . | quote }}
{{- /*
  Cube→Cube Store traffic goes over the HTTP/WebSocket port (httpPort, 3030
  by default). The meta port (9999) is the Cube Store cluster's INTERNAL
  router↔workers control plane — using it from the Cube API throws
  "CubeStore connection failed: read ECONNRESET" because that listener
  speaks a different protocol.
*/}}
- name: CUBEJS_CUBESTORE_PORT
  value: {{ .Values.cubestore.httpPort | quote }}
{{- end }}
{{- end -}}

{{- define "cubeStack.cubeEnv.redis" -}}
{{- if eq .Values.cube.cacheAndQueueDriver "redis" }}
{{- if .Values.redis.external.url }}
- name: CUBEJS_REDIS_URL
  value: {{ .Values.redis.external.url | quote }}
{{- if .Values.redis.external.passwordFromSecret.name }}
- name: CUBEJS_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redis.external.passwordFromSecret.name | quote }}
      key: {{ .Values.redis.external.passwordFromSecret.key | quote }}
{{- end }}
{{- if .Values.redis.external.tls }}
- name: CUBEJS_REDIS_TLS
  value: {{ .Values.redis.external.tls | quote }}
{{- end }}
- name: CUBEJS_REDIS_POOL_MIN
  value: {{ .Values.redis.external.poolMin | quote }}
- name: CUBEJS_REDIS_POOL_MAX
  value: {{ .Values.redis.external.poolMax | quote }}
{{- else if .Values.redis.enabled }}
- name: CUBEJS_REDIS_URL
  value: {{ printf "redis://%s-redis-master:6379" .Release.Name | quote }}
{{- if .Values.redis.auth.enabled }}
- name: CUBEJS_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.redis.auth.existingSecret }}
      name: {{ .Values.redis.auth.existingSecret | quote }}
      {{- else }}
      name: {{ printf "%s-redis" .Release.Name | quote }}
      {{- end }}
      key: redis-password
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "cubeStack.cubeEnv.jwt" -}}
{{- if .Values.cube.jwt.enabled }}
{{- if .Values.cube.jwt.audience }}
- name: CUBEJS_JWT_AUDIENCE
  value: {{ .Values.cube.jwt.audience | quote }}
{{- end }}
{{- if .Values.cube.jwt.issuer }}
- name: CUBEJS_JWT_ISSUER
  value: {{ .Values.cube.jwt.issuer | quote }}
{{- end }}
{{- if .Values.cube.jwt.algorithms }}
- name: CUBEJS_JWT_ALGS
  value: {{ .Values.cube.jwt.algorithms | quote }}
{{- end }}
{{- if .Values.cube.jwt.jwkUrl }}
- name: CUBEJS_JWK_URL
  value: {{ .Values.cube.jwt.jwkUrl | quote }}
{{- end }}
{{- if .Values.cube.jwt.claimsNamespace }}
- name: CUBEJS_JWT_CLAIMS_NAMESPACE
  value: {{ .Values.cube.jwt.claimsNamespace | quote }}
{{- end }}
{{- if .Values.cube.jwt.keyFromSecret.name }}
- name: CUBEJS_JWT_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cube.jwt.keyFromSecret.name | quote }}
      key: {{ .Values.cube.jwt.keyFromSecret.key | quote }}
{{- else if .Values.cube.jwt.key }}
- name: CUBEJS_JWT_KEY
  value: {{ .Values.cube.jwt.key | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Render env vars for every datasource. The first item is treated as the default
(uses CUBEJS_DB_*); subsequent ones use CUBEJS_DS_<NAME>_DB_*.
*/}}
{{- define "cubeStack.cubeEnv.datasources" -}}
{{- $names := list -}}
{{- range $name, $_ := .Values.datasources }}{{- $names = append $names $name -}}{{- end -}}
{{- $first := index $names 0 -}}
{{- range $name, $ds := .Values.datasources }}
{{- $isFirst := eq $name $first -}}
{{- $prefix := "CUBEJS_DB_" -}}
{{- if not $isFirst }}{{- $prefix = printf "CUBEJS_DS_%s_DB_" (upper $name) -}}{{- end }}
{{- if not $ds.type }}{{- fail (printf "datasources.%s.type is required" $name) -}}{{- end }}
- name: {{ printf "%sTYPE" $prefix }}
  value: {{ $ds.type | quote }}
{{- if $ds.host }}
- name: {{ printf "%sHOST" $prefix }}
  value: {{ $ds.host | quote }}
{{- end }}
{{- if $ds.port }}
- name: {{ printf "%sPORT" $prefix }}
  value: {{ $ds.port | quote }}
{{- end }}
{{- if $ds.database }}
- name: {{ printf "%sNAME" $prefix }}
  value: {{ $ds.database | quote }}
{{- end }}
{{- if $ds.user }}
- name: {{ printf "%sUSER" $prefix }}
  value: {{ $ds.user | quote }}
{{- end }}
{{- if $ds.existingSecret }}
- name: {{ printf "%sPASS" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ $ds.existingSecret | quote }}
      key: {{ default "password" $ds.passwordKey | quote }}
{{- else if $ds.password }}
- name: {{ printf "%sPASS" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: {{ printf "ds-%s-password" $name | quote }}
{{- end }}
{{- if $ds.maxPool }}
- name: {{ printf "%sMAX_POOL" $prefix }}
  value: {{ $ds.maxPool | quote }}
{{- end }}
{{- if (and $ds.ssl $ds.ssl.enabled) }}
- name: {{ printf "%sSSL" $prefix }}
  value: "true"
- name: {{ printf "%sSSL_REJECT_UNAUTHORIZED" $prefix }}
  value: {{ $ds.ssl.rejectUnauthorized | quote }}
{{- if $ds.ssl.ca }}
- name: {{ printf "%sSSL_CA" $prefix }}
  value: {{ $ds.ssl.ca | quote }}
{{- end }}
{{- end }}
{{- /* Pre-aggregation export bucket */ -}}
{{- with $ds.export }}
{{- if .bucket }}
- name: {{ printf "%sEXPORT_BUCKET" $prefix }}
  value: {{ .bucket | quote }}
{{- if .type }}
- name: {{ printf "%sEXPORT_BUCKET_TYPE" $prefix }}
  value: {{ .type | quote }}
{{- end }}
{{- if .region }}
- name: {{ printf "%sEXPORT_BUCKET_AWS_REGION" $prefix }}
  value: {{ .region | quote }}
{{- end }}
{{- if .integration }}
- name: {{ printf "%sEXPORT_INTEGRATION" $prefix }}
  value: {{ .integration | quote }}
{{- end }}
{{- if .aws.existingSecret }}
- name: {{ printf "%sEXPORT_BUCKET_AWS_KEY" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ .aws.existingSecret | quote }}
      key: {{ default "AWS_ACCESS_KEY_ID" .aws.keyKey | quote }}
- name: {{ printf "%sEXPORT_BUCKET_AWS_SECRET" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ .aws.existingSecret | quote }}
      key: {{ default "AWS_SECRET_ACCESS_KEY" .aws.secretKey | quote }}
{{- else if .aws.key }}
- name: {{ printf "%sEXPORT_BUCKET_AWS_KEY" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: {{ printf "ds-%s-export-aws-key" $name | quote }}
- name: {{ printf "%sEXPORT_BUCKET_AWS_SECRET" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ include "cubeStack.secrets.fullname" $ }}
      key: {{ printf "ds-%s-export-aws-secret" $name | quote }}
{{- end }}
{{- if .gcs.existingSecret }}
- name: {{ printf "%sEXPORT_GCS_CREDENTIALS" $prefix }}
  valueFrom:
    secretKeyRef:
      name: {{ .gcs.existingSecret | quote }}
      key: {{ default "credentials.json" .gcs.credentialsKey | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- range $ds.extraEnv }}
- {{ toYaml . | indent 2 | trim }}
{{- end }}
{{- end }}
{{- if gt (len $names) 1 }}
- name: CUBEJS_DATASOURCES
  value: {{ join "," $names | quote }}
{{- end }}
{{- end -}}

{{/*
S3/GCS/MINIO env vars for Cube data export buckets — only when the user has
configured cubestore.remoteStorage. Used by both Cube and Cube Store.
*/}}
{{- define "cubeStack.cubeEnv.s3" -}}
{{- with .Values.cubestore.remoteStorage }}
{{- if eq .type "s3" }}
- name: CUBESTORE_AWS_REGION
  value: {{ .s3.region | quote }}
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
{{- end }}
{{- end -}}

{{/*
Volumes/volume mounts for the Cube schema (config + model files).
schema.configMap or schema.git supplies /cube/conf.
*/}}
{{- define "cubeStack.schema.volumes" -}}
{{- if .Values.schema.configMap.enabled }}
- name: schema
  configMap:
    name: {{ include "cubeStack.schema.configmap.fullname" . }}
{{- else if .Values.schema.git.enabled }}
- name: schema
  emptyDir: {}
{{- if .Values.schema.git.auth.existingSecret }}
- name: git-auth
  secret:
    secretName: {{ .Values.schema.git.auth.existingSecret | quote }}
    defaultMode: 0400
{{- end }}
{{- else if .Values.quickstart.enabled }}
- name: schema
  configMap:
    name: {{ printf "%s-quickstart" (include "cubeStack.fullname" .) }}
    items:
      - key: cube.js
        path: cube.js
      - key: model_orders.yml
        path: model/orders.yml
{{- end }}
{{- end -}}

{{- define "cubeStack.schema.volumeMounts" -}}
{{- if or .Values.schema.configMap.enabled .Values.schema.git.enabled .Values.quickstart.enabled }}
- name: schema
  mountPath: {{ default "/cube/conf" .Values.schema.configMap.mountPath }}
{{- end }}
{{- end -}}

{{- define "cubeStack.schema.initContainers" -}}
{{- if .Values.schema.git.enabled }}
- name: git-clone
  image: "{{ .Values.schema.git.image.repository }}:{{ .Values.schema.git.image.tag }}"
  imagePullPolicy: {{ .Values.schema.git.image.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      mkdir -p /workspace
      cd /workspace
      {{- if .Values.schema.git.auth.existingSecret }}
      if [ -f /etc/git-auth/{{ .Values.schema.git.auth.tokenKey }} ]; then
        TOKEN=$(cat /etc/git-auth/{{ .Values.schema.git.auth.tokenKey }})
        REPO=$(echo "{{ .Values.schema.git.repoUrl }}" | sed "s#https://#https://oauth2:${TOKEN}@#")
      elif [ -f /etc/git-auth/{{ .Values.schema.git.auth.sshKeyKey }} ]; then
        export GIT_SSH_COMMAND="ssh -i /etc/git-auth/{{ .Values.schema.git.auth.sshKeyKey }} -o StrictHostKeyChecking=no"
        REPO="{{ .Values.schema.git.repoUrl }}"
      fi
      {{- else }}
      REPO="{{ .Values.schema.git.repoUrl }}"
      {{- end }}
      git clone --depth 1 --branch "{{ .Values.schema.git.ref }}" "$REPO" repo
      {{- if .Values.schema.git.subPath }}
      cp -r repo/{{ .Values.schema.git.subPath }}/. /workspace/out/
      {{- else }}
      cp -r repo/. /workspace/out/
      {{- end }}
  volumeMounts:
    - name: schema
      mountPath: /workspace/out
    {{- if .Values.schema.git.auth.existingSecret }}
    - name: git-auth
      mountPath: /etc/git-auth
      readOnly: true
    {{- end }}
  {{- with .Values.schema.git.resources }}
  resources: {{ toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Has-cloud-bucket helper used to switch off the shared-PVC fallback.
*/}}
{{- define "cubeStack.cubestore.hasCloudBucket" -}}
{{- $rs := .Values.cubestore.remoteStorage -}}
{{- if or (eq $rs.type "s3") (eq $rs.type "gcs") (eq $rs.type "minio") -}}true{{- end -}}
{{- end -}}

{{- define "cubeStack.cubestore.usesSharedPvc" -}}
{{- if eq .Values.cubestore.remoteStorage.type "shared-pvc" -}}true{{- end -}}
{{- end -}}
