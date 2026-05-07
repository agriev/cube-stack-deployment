{{/*
PR-T2 — Inter-node TLS for Raft / cube-stack-ha.

This file contains the *helper templates* the future TLS-enabled
StatefulSets will call. The TLS-aware Cube Store image is the agriev/
cube fork's `cubestore-ha:v0.2.0+` (a future release that adds the
rustls TcpTransport behind `CUBESTORE_RAFT_TLS_*` env vars).

Until that image ships, `cubestore.tls.enabled: false` is the default
and these helpers no-op. When `cubestore.tls.enabled: true`, the
`_validations.tpl` guard fires unless the operator explicitly
acknowledges they're on the v0.2+ image (`tls.acknowledgeImageTag: true`).

Usage from a concrete StatefulSet template (router or workers):

    {{- include "cubeStack.cubestore.tls.envVars" . | nindent 12 }}
    {{- include "cubeStack.cubestore.tls.volumeMounts" . | nindent 12 }}
    {{- include "cubeStack.cubestore.tls.volumes" . | nindent 8 }}
*/}}

{{- define "cubeStack.cubestore.tls.envVars" -}}
{{- if (dig "tls" "enabled" false .Values.cubestore) }}
- name: CUBESTORE_RAFT_TLS_ENABLED
  value: "true"
- name: CUBESTORE_RAFT_TLS_CERT_FILE
  value: /etc/cubestore/tls/tls.crt
- name: CUBESTORE_RAFT_TLS_KEY_FILE
  value: /etc/cubestore/tls/tls.key
- name: CUBESTORE_RAFT_TLS_CA_FILE
  value: /etc/cubestore/tls/ca.crt
- name: CUBESTORE_RAFT_TLS_CLIENT_AUTH
  value: {{ default "require" (dig "tls" "clientAuth" "" .Values.cubestore) | quote }}
{{- end }}
{{- end -}}

{{- define "cubeStack.cubestore.tls.volumeMounts" -}}
{{- if (dig "tls" "enabled" false .Values.cubestore) }}
- name: cubestore-tls
  mountPath: /etc/cubestore/tls
  readOnly: true
{{- end }}
{{- end -}}

{{- define "cubeStack.cubestore.tls.volumes" -}}
{{- if (dig "tls" "enabled" false .Values.cubestore) }}
- name: cubestore-tls
  secret:
    secretName: {{ required "cubestore.tls.existingSecret is required when cubestore.tls.enabled" (dig "tls" "existingSecret" "" .Values.cubestore) }}
    defaultMode: 0400
{{- end }}
{{- end -}}
