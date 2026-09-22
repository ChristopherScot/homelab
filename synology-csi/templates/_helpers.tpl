{{/*
Expand the name of the chart.
*/}}
{{- define "synology-csi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "synology-csi.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "synology-csi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "synology-csi.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{ include "synology-csi.selectorLabels" . }}
helm.sh/chart: {{ include "synology-csi.chart" . }}
{{- end }}

{{/*
Selector Labels:
*/}}
{{- define "synology-csi.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "synology-csi.name" . }}
helm.sh/template: {{ .Template.Name | trimPrefix .Template.BasePath | trimPrefix "/" | replace "/" "_" }}
{{- end }}

{{/*
Client Info Secret Volume:
*/}}
{{- define "synology-csi.clientInfoSecretVolume" -}}
name: client-info
secret:
  secretName: {{ .Values.clientInfoSecret.name | default (include "synology-csi.fullname" . | printf "%s-client-info") }}
{{- end }}

{{/*
Init container that blocks csi-plugin startup until DSM serves its web
API. Shared by the node DaemonSet and the controller StatefulSet, which
both log in once at startup and never retry.
*/}}
{{- define "synology-csi.waitForDsm" -}}
# Block the plugin from starting until DSM's web API actually
# answers.
#
# Why this is needed: the driver logs into DSM exactly ONCE, in
# AddDsm() at startup. On failure the DSM is never added to its
# in-memory map, and GetDsm() then fails forever with
# "Failed to get DSM[<ip>]". There is no retry and no re-login
# path in the driver, so a plugin that starts while the NAS is
# down stays permanently broken until something restarts it.
#
# That is exactly what a whole-house power cut does: the cluster
# boots faster than the NAS, every csi-plugin loses its login,
# and every Synology-backed pod hangs in ContainerCreating until
# the DaemonSet is restarted by hand. Seen 2026-09-22 — six media
# pods stuck 25+ minutes while the NAS itself was healthy.
#
# A csi-livenessprobe sidecar does NOT solve this: the driver's
# Probe RPC is a hardcoded `return &csi.ProbeResponse{}, nil`
# that never touches DSM, so it reports healthy throughout.
# Gating startup is the only lever that works without patching
# upstream.
#
# Host and port are read from the mounted client-info secret so
# the NAS address lives in exactly one place (Vault).
- name: wait-for-dsm
  {{- with $.Values.images.plugin }}
  image: {{ .image }}:{{ .tag | default $.Chart.AppVersion }}
  imagePullPolicy: {{ .pullPolicy }}
  {{- end }}
  command:
    - /bin/sh
    - -c
    - |
      set -eu
      CI=/etc/synology/client-info.yml
      host=$(sed -n 's/.*host:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$CI" | head -1)
      port=$(sed -n 's/.*port:[[:space:]]*\([0-9]*\).*/\1/p' "$CI" | head -1)
      https=$(sed -n 's/.*https:[[:space:]]*\([a-z]*\).*/\1/p' "$CI" | head -1)
      if [ "$https" = "true" ]; then scheme=https; : "${port:=5001}"
      else scheme=http; : "${port:=5000}"; fi
      if [ -z "$host" ]; then
        echo "could not parse host from $CI; not gating startup"
        exit 0
      fi
      # Query DSM's web API, not just the TCP port. During the
      # 2026-09-22 outage ports 5000/5001 accepted connections
      # while the API was still not serving, so a port check
      # alone would have let the plugin start too early and
      # poison itself exactly as before.
      url="$scheme://$host:$port/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query"
      # Cap the wait so a permanently-dead NAS surfaces as a
      # CrashLoopBackOff we can alert on, rather than a pod that
      # hangs in Init forever with no signal.
      deadline=$(( $(date +%s) + {{ $.Values.node.waitForDsm.timeoutSeconds }} ))
      while :; do
        if wget -q --no-check-certificate -T 8 -O - "$url" 2>/dev/null | grep -q 'SYNO.API.Auth'; then
          echo "DSM $host:$port is serving its API; starting csi-plugin"
          break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "DSM $host:$port did not serve its API within {{ $.Values.node.waitForDsm.timeoutSeconds }}s; giving up so this pod restarts"
          exit 1
        fi
        echo "waiting for DSM API at $host:$port ..."
        sleep 5
      done
  volumeMounts:
    - name: client-info
      mountPath: /etc/synology
      readOnly: true
{{- end }}
