{{/*
Common PrometheusRule alerts shared by cube-stack and cube-stack-ha.
HA-specific Raft alerts live in cube-stack-ha's local prometheusrule.yaml.

Usage from a concrete chart:

  spec:
    groups:
      - name: cube-stack-common
        rules:
          {{- include "cubeStack.prometheusRule.commonRules" . | nindent 10 }}

Selector strategy: alerts join Prometheus's standard `up`/kubelet
metrics with kube-state-metrics' `kube_pod_labels` to filter on the
chart's `app.kubernetes.io/part-of=cube-stack` label. If your
Prometheus install lacks kube-state-metrics, replace these with
plain `up{job="..."}` style — see the PrometheusRule annotations on
each alert for the simpler form.
*/}}
{{- define "cubeStack.prometheusRule.commonRules" -}}
- alert: CubeApiPodNotReady
  expr: |
    (kube_pod_status_ready{condition="true"} == 0)
      and on (namespace, pod)
    kube_pod_labels{label_app_kubernetes_io_component="api", label_app_kubernetes_io_part_of="cube-stack"}
  for: 5m
  labels:
    severity: critical
    chart: {{ .Chart.Name }}
  annotations:
    summary: "Cube API pod {{`{{ $labels.pod }}`}} not Ready for 5m"
    description: "kubectl -n {{`{{ $labels.namespace }}`}} describe pod {{`{{ $labels.pod }}`}}"

- alert: CubeStoreRouterPodNotReady
  expr: |
    (kube_pod_status_ready{condition="true"} == 0)
      and on (namespace, pod)
    kube_pod_labels{label_app_kubernetes_io_component="cubestore-router", label_app_kubernetes_io_part_of="cube-stack"}
  for: 2m
  labels:
    severity: critical
    chart: {{ .Chart.Name }}
  annotations:
    summary: "Cube Store router pod {{`{{ $labels.pod }}`}} not Ready for 2m"
    description: |
      In the vanilla chart this disables the entire release; in the HA
      chart, surviving routers keep serving as long as quorum holds.

- alert: CubeStorePVCNearFull
  expr: |
    (
      kubelet_volume_stats_available_bytes{persistentvolumeclaim=~".*-cubestore-.*"}
      /
      kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~".*-cubestore-.*"}
    ) < 0.15
  for: 10m
  labels:
    severity: warning
    chart: {{ .Chart.Name }}
  annotations:
    summary: "Cube Store PVC {{`{{ $labels.persistentvolumeclaim }}`}} <15% free"
    description: |
      Routers run the RocksDB metastore (and in HA the Raft log) on the
      same PVC; running it out has caused router crash-loops in past
      incidents. Plan for PVC resize or pre-aggregation cleanup.

- alert: CubeRefreshWorkerCrashLooping
  expr: |
    rate(kube_pod_container_status_restarts_total[10m]) > 0
      and on (namespace, pod)
    kube_pod_labels{label_app_kubernetes_io_component="refresh-worker", label_app_kubernetes_io_part_of="cube-stack"}
  for: 5m
  labels:
    severity: warning
    chart: {{ .Chart.Name }}
  annotations:
    summary: "Refresh worker {{`{{ $labels.pod }}`}} restarting"
    description: "Refresh-worker has restarted in the last 10 minutes; pre-aggregations may be falling behind."
{{- end -}}
