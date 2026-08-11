{{/* チャート名。名前の衝突を避けるため全リソースの接頭辞に使う */}}
{{- define "time-tracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* 全リソース共通ラベル。ArgoCD の差分表示やセレクタの基点になる */}}
{{- define "time-tracker.labels" -}}
app.kubernetes.io/name: {{ include "time-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* コンポーネント(backend/frontend/postgresql)のセレクタラベル。
     Deployment の selector は immutable なので、ここを変えると再作成が要る */}}
{{- define "time-tracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "time-tracker.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* イメージの完全参照。registry/project/repository:tag */}}
{{- define "time-tracker.image" -}}
{{- printf "%s/%s/%s:%s" .root.Values.image.registry .root.Values.image.project .repository .tag -}}
{{- end -}}

{{/* PostgreSQL の接続 URL。パスワードは Secret から env で注入するため
     ここでは $(POSTGRES_PASSWORD) の形で残し、コンテナ内で展開させる */}}
{{- define "time-tracker.databaseUrl" -}}
{{- printf "postgres://%s:$(POSTGRES_PASSWORD)@%s-%s:%d/%s" .Values.postgresql.user (include "time-tracker.name" .) .Values.postgresql.name (int .Values.postgresql.port) .Values.postgresql.database -}}
{{- end -}}
