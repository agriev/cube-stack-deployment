{{/*
Anti-affinity for the Cube Store router StatefulSet (HA mode).

Why hostname (not zone) by default — the most common cluster failure
that breaks Raft quorum is a SINGLE node going down (kubelet OOM,
cordon, kernel panic). If two routers happen to be on the same node,
that single failure takes down two of three routers and the cluster
becomes unwriteable. Hostname anti-affinity prevents this and degrades
gracefully on single-node dev clusters via `type: preferred`. Zone
spread is a softer guarantee that requires multi-zone clusters and
breaks single-node kind/docker-desktop.

User precedence (highest first):
  1. .Values.cubestore.router.affinity — full custom block, helper bypassed
  2. .Values.cubestore.antiAffinity.{enabled,type,topologyKey} — knobs
  3. Helper default — required by hostname

Usage from a StatefulSet/Deployment template:

  {{- $aff := include "cubeStack.cubestore.router.affinity" . }}
  {{- if trim $aff }}
  affinity:
    {{- $aff | nindent 8 }}
  {{- end }}
*/}}
{{- define "cubeStack.cubestore.router.affinity" -}}
{{- if .Values.cubestore.router.affinity -}}
{{ toYaml .Values.cubestore.router.affinity }}
{{- else -}}
{{- $aa := default (dict) .Values.cubestore.antiAffinity -}}
{{- if and $aa.enabled $aa.type -}}
{{- $topologyKey := default "kubernetes.io/hostname" $aa.topologyKey -}}
podAntiAffinity:
{{- if eq $aa.type "required" }}
  requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: {{ $topologyKey | quote }}
      labelSelector:
        matchLabels:
          {{- include "cubeStack.componentSelectorLabels" (dict "ctx" . "component" "cubestore-router") | nindent 10 }}
{{- else if eq $aa.type "preferred" }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: {{ $topologyKey | quote }}
        labelSelector:
          matchLabels:
            {{- include "cubeStack.componentSelectorLabels" (dict "ctx" . "component" "cubestore-router") | nindent 12 }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}
