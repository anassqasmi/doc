{{- define "nginx-istio.fullname" -}}
{{- .Release.Name }}-nginx-istio
{{- end -}}

{{- define "nginx-istio.labels" -}}
app.kubernetes.io/name: {{ include "nginx-istio.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
