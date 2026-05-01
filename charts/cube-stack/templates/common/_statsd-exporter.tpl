{{/*
StatsD-to-Prometheus sidecar shared by Cube Store router and workers.
Set .Values.metrics.statsdExporter.enabled to install.
*/}}
{{- define "cubeStack.statsdExporter.container" -}}
- name: statsd-exporter
  image: "{{ .Values.metrics.statsdExporter.image.repository }}:{{ .Values.metrics.statsdExporter.image.tag }}"
  imagePullPolicy: {{ .Values.metrics.statsdExporter.image.pullPolicy }}
  securityContext: {{- toYaml .Values.containerSecurityContext | nindent 4 }}
  args:
    - --web.listen-address=:{{ .Values.metrics.statsdExporter.httpPort }}
    - --statsd.listen-udp=:{{ .Values.metrics.statsdExporter.statsdPort }}
  ports:
    - name: metrics
      containerPort: {{ .Values.metrics.statsdExporter.httpPort }}
      protocol: TCP
    - name: statsd
      containerPort: {{ .Values.metrics.statsdExporter.statsdPort }}
      protocol: UDP
  resources: {{- toYaml .Values.metrics.statsdExporter.resources | nindent 4 }}
{{- end -}}
