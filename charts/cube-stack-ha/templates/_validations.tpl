{{/*
Fail-fast validations rendered before any resource. Helm aborts the install
when `fail` is reached, so this catches obvious misconfigurations early.
The actual call is made from common/_validations-call.yaml.
*/}}
{{- define "cubeStack.validate" -}}
{{- /* Cache & queue driver */ -}}
{{- $allowedDrivers := list "cubestore" "redis" -}}
{{- if not (has .Values.cube.cacheAndQueueDriver $allowedDrivers) -}}
{{- fail (printf "cube.cacheAndQueueDriver must be one of: %s" (join ", " $allowedDrivers)) -}}
{{- end -}}

{{- /* Datasources are mandatory */ -}}
{{- if not .Values.datasources -}}
{{- fail "At least one entry under .Values.datasources is required (e.g. datasources.default)." -}}
{{- end -}}

{{- /* Cube Store remote storage backend */ -}}
{{- $allowedBackends := list "" "shared-pvc" "s3" "gcs" "minio" -}}
{{- if not (has .Values.cubestore.remoteStorage.type $allowedBackends) -}}
{{- fail (printf "cubestore.remoteStorage.type must be one of: %s" (join ", " $allowedBackends)) -}}
{{- end -}}

{{- /* topologySpread global value */ -}}
{{- $allowedSpread := list "" "soft" "hard" -}}
{{- if not (has .Values.global.topologySpread $allowedSpread) -}}
{{- fail (printf "global.topologySpread must be one of: %s" (join ", " $allowedSpread)) -}}
{{- end -}}

{{- /* Redis required when driver is redis */ -}}
{{- if eq .Values.cube.cacheAndQueueDriver "redis" -}}
{{- if and (not .Values.redis.enabled) (not .Values.redis.external.url) -}}
{{- fail "cube.cacheAndQueueDriver=redis requires redis.enabled=true or redis.external.url to be set." -}}
{{- end -}}
{{- end -}}

{{- /* Datasource hosts must be set unless quickstart is on */ -}}
{{- if not .Values.quickstart.enabled -}}
{{- range $name, $ds := .Values.datasources -}}
{{- if and (eq $ds.type "postgres") (not $ds.host) (not (or $ds.url ($ds.url | default ""))) -}}
{{- fail (printf "datasources.%s.host is required (or enable quickstart.enabled=true to deploy with the bundled demo schema)" $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Schema source must be supplied unless quickstart is on */ -}}
{{- if not .Values.quickstart.enabled -}}
{{- if not (or .Values.schema.configMap.enabled .Values.schema.git.enabled) -}}
{{- /* OK — assume schema is baked into a custom image. Print a polite hint. */ -}}
{{- end -}}
{{- end -}}

{{- /* Cube Store cluster sanity */ -}}
{{- if and .Values.cubestore.enabled (eq (.Values.cubestore.workers.replicas | int) 0) -}}
{{- /* Allowed (single-node mode) but log via NOTES.txt — see warning there. */ -}}
{{- end -}}

{{- /* SQL API password set when user is set */ -}}
{{- if and .Values.cube.sqlAuth.user (not .Values.cube.sqlAuth.password) (not .Values.cube.sqlAuth.existingSecret) -}}
{{- /* Auto-generates random password — that's fine. */ -}}
{{- end -}}

{{- /* PR-T2: TLS pre-flight — requires v0.2+ image. */ -}}
{{- if (dig "tls" "enabled" false .Values.cubestore) -}}
{{- if not (dig "tls" "existingSecret" "" .Values.cubestore) -}}
{{- fail "cubestore.tls.enabled=true requires cubestore.tls.existingSecret to be set (mount a TLS-typed Secret with tls.crt + tls.key + ca.crt)." -}}
{{- end -}}
{{- if not (dig "tls" "acknowledgeImageTag" false .Values.cubestore) -}}
{{- fail "cubestore.tls.enabled=true requires the agriev/cube cubestore-ha:v0.2.0+ image (rustls-backed transport). Set cubestore.tls.acknowledgeImageTag=true to confirm you're on v0.2+. See docs/ha/RAFT-TLS-DESIGN.md." -}}
{{- end -}}
{{- $authMode := default "require" (dig "tls" "clientAuth" "" .Values.cubestore) -}}
{{- $allowedAuth := list "none" "optional" "require" -}}
{{- if not (has $authMode $allowedAuth) -}}
{{- fail (printf "cubestore.tls.clientAuth must be one of: %s" (join ", " $allowedAuth)) -}}
{{- end -}}
{{- end -}}

{{- /* HA fork — Raft replication requires an odd, ≥3 replica count. */ -}}
{{- if and .Values.cubestore.enabled .Values.cubestore.ha.enabled -}}
{{- $replicas := .Values.cubestore.router.replicas | int -}}
{{- if lt $replicas 3 -}}
{{- fail (printf "cubestore.ha.enabled=true requires cubestore.router.replicas >= 3 (got %d). Raft quorum is (N/2)+1 — 1 or 2 replicas can't survive a single failure." $replicas) -}}
{{- end -}}
{{- if eq (mod $replicas 2) 0 -}}
{{- fail (printf "cubestore.ha.enabled=true requires an ODD cubestore.router.replicas (got %d). Even replica counts let half-and-half partitions block writes indefinitely." $replicas) -}}
{{- end -}}
{{- if not .Values.cubestore.router.persistence.enabled -}}
{{- fail "cubestore.ha.enabled=true requires cubestore.router.persistence.enabled=true. Raft log durability depends on a stable PVC; emptyDir would lose committed entries on pod restart." -}}
{{- end -}}
{{- end -}}
{{- end -}}
