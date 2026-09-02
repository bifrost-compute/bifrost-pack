{{/*
Chart name, overridable with nameOverride.
*/}}
{{- define "bifrost-pack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. values.yaml ships fullnameOverride: bifrost so the
default install produces short, predictable object names ("bifrost",
"bifrost-ui") and a short derived Keycloak client id. Clear fullnameOverride
to get the standard release-scoped names — required if you install more than
one Bifrost release into the same namespace.
*/}}
{{- define "bifrost-pack.fullname" -}}
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

{{- define "bifrost-pack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bifrost-pack.labels" -}}
helm.sh/chart: {{ include "bifrost-pack.chart" . }}
{{ include "bifrost-pack.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "bifrost-pack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bifrost-pack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Dashboard (bifrost-ui) names/labels. A distinct app.kubernetes.io/name so the
UI Deployment and Service selectors never overlap the control plane's.
*/}}
{{- define "bifrost-pack.ui.fullname" -}}
{{- printf "%s-ui" (include "bifrost-pack.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bifrost-pack.ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bifrost-pack.name" . }}-ui
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bifrost-pack.ui.labels" -}}
helm.sh/chart: {{ include "bifrost-pack.chart" . }}
{{ include "bifrost-pack.ui.selectorLabels" . }}
app.kubernetes.io/component: dashboard
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "bifrost-pack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bifrost-pack.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
The namespace Bifrost reconciles RayClusters/RayServices into — `serve
--namespace`. Empty means the release namespace.
*/}}
{{- define "bifrost-pack.rayNamespace" -}}
{{- .Values.ray.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Name of the API NebariApp. This is load-bearing beyond the CR itself: the
nebari-operator derives the Keycloak client id it provisions as
`<namespace>-<nebariapp-name>` (nebari-operator internal/controller/utils/
naming/naming.go, ClientID), and that id is what lands in the `aud` claim
Bifrost validates. See "bifrost-pack.oidcAudience".
*/}}
{{- define "bifrost-pack.apiNebariAppName" -}}
{{- include "bifrost-pack.fullname" . }}
{{- end }}

{{- define "bifrost-pack.uiNebariAppName" -}}
{{- include "bifrost-pack.ui.fullname" . }}
{{- end }}

{{/*
The `aud` value Bifrost requires on presented JWTs.

FIRST-BOOT ORDERING (deliberate): the operator writes the provisioned client
credentials to Secret `<nebariapp-name>-oidc-client` (keys issuer-url,
client-id, client-secret) only AFTER its first reconcile. If the Deployment
sourced the audience from that Secret, the very first boot would race the
operator and be non-deterministic.

It does not have to. Bifrost only VALIDATES bearer tokens — it needs the
issuer (for OIDC discovery + JWKS) and the expected audience, never the
client secret. The client id is a pure function of values already known at
template time (`<release-namespace>-<api-nebariapp-name>`), so the audience is
computed here and baked into the ConfigMap. Nothing in this chart reads the
OIDC Secret, no env ref is optional-vs-required, and boot order is
irrelevant.

Precedence, in order:
  1. an explicit auth.oidc.audience always wins — use it when the Keycloak
     client is provisioned out of band, or when an audience mapper puts a
     different value in `aud`;
  2. otherwise, when the API NebariApp provisions a client, the operator's
     derived client id;
  3. otherwise the standalone default, "bifrost", for a hand-registered
     client.

Note that (2) means turning nebariApp.api on CHANGES the expected audience.
That is intended — the provisioned client is the one issuing the tokens — but
it is why NOTES.txt prints the effective value on every install and upgrade.
*/}}
{{/*
Whether `--local-auth` is on: auth.mode=local always; auth.mode=oidc when
auth.local.enabled. The binary accepts both flags together (local users and
bfr_ PATs beside OIDC bearers); the chart used to force a choice.
*/}}
{{- define "bifrost-pack.localAuthEnabled" -}}
{{- if or (eq .Values.auth.mode "local") (and (eq .Values.auth.mode "oidc") .Values.auth.local.enabled) -}}true{{- end -}}
{{- end }}

{{/*
The OIDC public client id the dashboard SPA authenticates as, served at
/config.json. Explicit ui.sso.clientId wins; otherwise the SPA client the
operator provisions for the UI NebariApp (spaClient.clientID, or the derived
<namespace>-<ui-nebariapp-name>-spa — nebari-operator GetSPAClientID);
otherwise the UI's compiled default.
*/}}
{{- define "bifrost-pack.uiSsoClientId" -}}
{{- if .Values.ui.sso.clientId -}}
{{- .Values.ui.sso.clientId -}}
{{- else if and .Values.nebariApp.ui.enabled .Values.nebariApp.ui.auth.enabled .Values.nebariApp.ui.auth.spaClient.enabled -}}
{{- .Values.nebariApp.ui.auth.spaClient.clientID | default (printf "%s-%s-spa" .Release.Namespace (include "bifrost-pack.uiNebariAppName" .)) -}}
{{- else -}}
{{- "bifrost" -}}
{{- end -}}
{{- end }}

{{- define "bifrost-pack.uiSsoIssuer" -}}
{{- if .Values.ui.sso.issuer -}}
{{- .Values.ui.sso.issuer -}}
{{- else if eq .Values.auth.mode "oidc" -}}
{{- .Values.auth.oidc.issuer -}}
{{- end -}}
{{- end }}

{{- define "bifrost-pack.oidcAudience" -}}
{{- if .Values.auth.oidc.audience -}}
{{- .Values.auth.oidc.audience -}}
{{- else if and .Values.nebariApp.api.enabled .Values.nebariApp.api.auth.enabled (.Values.nebariApp.api.auth.provisionClient | default false) -}}
{{- printf "%s-%s" .Release.Namespace (include "bifrost-pack.apiNebariAppName" .) -}}
{{- else -}}
{{- "bifrost" -}}
{{- end -}}
{{- end }}

{{/*
Value validation, included once from deployment.yaml so a bad values file
fails at `helm template`/`helm install` rather than in a CrashLoopBackOff.
*/}}
{{- define "bifrost-pack.validate" -}}
{{- if not (has .Values.auth.mode (list "oidc" "local" "none")) -}}
{{- fail (printf "auth.mode must be one of oidc|local|none, got %q" .Values.auth.mode) -}}
{{- end -}}
{{- if eq .Values.auth.mode "oidc" -}}
{{- if not .Values.auth.oidc.issuer -}}
{{- fail "auth.oidc.issuer is required when auth.mode=oidc" -}}
{{- end -}}
{{- end -}}
{{- if and (eq .Values.auth.mode "none") (not .Values.auth.dangerousDevAllowUnauthenticated) -}}
{{- fail "auth.mode=none serves WITHOUT authentication: anyone who can reach :8484 can run code on every cluster Bifrost manages. Set auth.dangerousDevAllowUnauthenticated=true to confirm." -}}
{{- end -}}
{{- if not (has .Values.store.kind (list "memory" "sqlite" "postgres")) -}}
{{- fail (printf "store.kind must be one of memory|sqlite|postgres, got %q" .Values.store.kind) -}}
{{- end -}}
{{- if and (eq .Values.store.kind "postgres") (not .Values.store.postgres.dsn) -}}
{{- fail "store.postgres.dsn is required when store.kind=postgres" -}}
{{- end -}}
{{- if and (ne .Values.store.kind "postgres") (gt (int .Values.replicaCount) 1) -}}
{{- fail "replicaCount>1 requires store.kind=postgres (memory is per-pod; SQLite is a single writer on an RWO PVC)" -}}
{{- end -}}
{{- if and .Values.gateway.externalBase (not .Values.gateway.domain) -}}
{{- fail "gateway.externalBase only prefixes the `<name>.<gateway.domain>` hostname Bifrost reports as gateway_url; set gateway.domain (which turns dynamic registration on) or clear gateway.externalBase" -}}
{{- end -}}
{{- if lt (int .Values.services.perProject) 1 -}}
{{- fail (printf "services.perProject must be >= 1 (1 = one Serve application per project, the design; higher is the escape hatch), got %v" .Values.services.perProject) -}}
{{- end -}}
{{/*
Constraint: the `ray` namespace on a Nebari cluster is occupied by
rayserve-pack's `shared` release (Grace). Two controllers reconciling one
namespace is the failure this guard exists to prevent — Bifrost's own
ownership-label scoping keeps it from touching rayserve-pack's objects, but
the shared namespace still collides on NetworkPolicy posture and PSS labels.
*/}}
{{- if and (eq (include "bifrost-pack.rayNamespace" .) "ray") (not .Values.ray.allowRayNamespace) -}}
{{- fail "the `ray` namespace is reserved for rayserve-pack on Nebari clusters; set ray.namespace (default: the release namespace, e.g. `bifrost`) or ray.allowRayNamespace=true to override" -}}
{{- end -}}
{{- end }}
