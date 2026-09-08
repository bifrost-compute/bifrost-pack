# bifrost-pack

A [Nebari](https://www.nebari.dev/) software pack for
[Bifrost](https://github.com/brandonrc/bifrost) — the Go control plane for Ray
and Dask clusters.

Bifrost is the guarded bridge to a compute cluster: a REST API on `:8484` that
validates OIDC bearer tokens, applies deny-by-default RBAC, provisions
self-serve RayClusters through KubeRay, manages Kueue resource pools, and
federates the Ray Jobs API so users never touch a Ray dashboard, GCS port or
job endpoint directly.

This repo is the pack: one Helm chart under [`chart/`](chart/) plus the
[`pack-metadata.yaml`](pack-metadata.yaml) the Nebari pack dashboard scrapes.
It is the successor to `mobula-pack`, the pack for Bifrost's Rust predecessor.

> **Status: experimental.** Both of the blockers this section used to list are
> now cleared. The [bifrost repo](https://github.com/brandonrc/bifrost)
> publishes `ghcr.io/brandonrc/bifrost` on every push to `main`, tagged
> `sha-<short>` (immutable, preferred) and `latest` — `image.tag` is required,
> because `.Chart.AppVersion` is *not* a published tag. The dashboard's OIDC
> client id is configurable via `VITE_BIFROST_SSO_CLIENT_ID`, so it can match
> an operator-provisioned Keycloak client instead of a hardcoded name.
>
> Still experimental for the reasons in the requirement table: ephemeral
> RayJob, group model serving, and the serving resource pool are not built.

## What gets deployed

| Object | Purpose |
| --- | --- |
| `Deployment` + `Service` | The control plane, `bifrost serve` on `:8484` |
| `ServiceAccount` + `Role`/`ClusterRole` | Exactly the Kubernetes API access the reconciler uses — see [RBAC](#rbac) |
| `ConfigMap` | The OIDC validator config (`auth.json`) and the job-gateway cluster registry (`clusters.json`) |
| `PersistentVolumeClaim` | SQLite desired-state store (`store.kind=sqlite`) |
| `NebariApp` | Routes the API through the shared Envoy Gateway and provisions a Keycloak client |
| `NetworkPolicy` | Optional ingress restriction on the control plane |
| Dashboard `Deployment`/`Service`/`ConfigMap` + a second `NebariApp` | Optional, off by default (`ui.enabled`) |

## Quick start

```sh
helm dependency update chart

kubectl create namespace bifrost
kubectl label namespace bifrost nebari.dev/managed=true --overwrite
kubectl label namespace bifrost bifrost.dev/control-plane=true --overwrite

helm install bifrost ./chart -n bifrost \
  --set image.repository=<your-registry>/bifrost \
  --set image.tag=<tag> \
  --set auth.oidc.issuer=https://nebari.example.com/auth/realms/nebari \
  --set nebariApp.api.enabled=true \
  --set nebariApp.api.hostname=bifrost.nebari.example.com
```

For a full local stack (kind + MetalLB + Envoy Gateway + cert-manager +
Keycloak + nebari-operator + KubeRay), see [`dev/Makefile`](dev/Makefile):

```sh
cd dev && make up
```

## The four constraints that shape this chart

### 1. `kuberay-operator.enabled` is `false`, and stays false

The chart declares kuberay-operator 1.4.0 as an optional subchart, disabled by
default. Exactly one KubeRay operator may own a cluster's `ray.io` CRDs, and
Helm installs CRDs on first install **only** — it never upgrades them. Nebari
clusters already run one (Grace: 1.4.0 cluster-wide; `rayserve-pack` vendors
1.3.0 of its own). Whichever chart installs first owns the CRDs and every
later one silently runs against a schema it did not install.

Enable the subchart only on a bare cluster with no KubeRay at all.

### 2. `ray.namespace` must not be `ray`

`rayserve-pack`'s `shared` release occupies the `ray` namespace on Nebari
clusters. The chart defaults `ray.namespace` to the release namespace and
**refuses to template** when it resolves to `ray` (override with
`ray.allowRayNamespace=true` if you really mean it).

This is not about the RayClusters — see below — but about the namespace-level
posture. Bifrost applies a default-deny NetworkPolicy, a tenant-allow, and Pod
Security Standards labels to whatever namespace it reconciles into. Doing that
to a namespace another pack owns is a bad afternoon.

### 3. Ownership-label scoping (already correct in the server)

Bifrost's reconciler never enumerates a namespace. It lists RayClusters and
RayServices with the selector `app.kubernetes.io/managed-by=bifrost`, the same
value it uses as its server-side-apply field manager
(`internal/provision/live/client.go`, `List` / `ServiceClient.List`). A
RayService created by `rayserve-pack` is invisible to it and can never be
reconciled or reaped.

The label value is a compile-time constant (`provision.FieldManager`), not a
flag, so there is nothing to configure here and no chart value for it. That is
the right design — an ownership label you can point somewhere else is an
ownership label you can point at somebody else's objects.

### 4. Gateway auth: client provisioned, enforcement off

The API `NebariApp` sets `provisionClient: true` with
`enforceAtGateway: false`.

Bifrost validates OIDC bearer tokens in-process — caller credentials terminate
at the control plane and only the cluster's own static token travels
southbound. If Envoy enforced OIDC in front of it, `ray job submit`, the
`bifrost` CLI, and every `curl` would get an HTML redirect to a Keycloak login
page instead of a JSON response. So the operator provisions the Keycloak
client (that is what `provisionClient` is for) and the gateway stays a
transparent proxy.

## First boot and the OIDC client Secret

The nebari-operator writes provisioned client credentials to Secret
`<nebariapp-name>-oidc-client` (keys `issuer-url`, `client-id`,
`client-secret`) — but only **after** its first reconcile. Anything that
referenced that Secret at pod-start time would race it.

Nothing in this chart references it. Bifrost only *validates* tokens, so it
needs the issuer and the expected audience, never the client secret. Both are
known at template time:

- the **issuer** comes from `auth.oidc.issuer`, which you supply;
- the **audience** is the client id, and the operator derives that
  deterministically as `<namespace>-<nebariapp-name>`
  (`nebari-operator/internal/controller/utils/naming/naming.go`, `ClientID`),
  so the chart computes the same string.

The result is a `ConfigMap` with a complete `auth.json` before the pod ever
starts. First boot is deterministic; there is no optional-vs-required env ref
to get wrong. `NOTES.txt` prints the effective audience on every install so a
mismatch is visible immediately, and `auth.oidc.audience` overrides it when
the client is provisioned out of band or a Keycloak audience mapper puts
something else in `aud`.

## RBAC

Every rule in [`chart/templates/rbac.yaml`](chart/templates/rbac.yaml) is
derived from an actual call in `bifrost/internal/provision/live/client.go`,
the only package in Bifrost that opens a connection to an API server. The
rendered rules and the reasoning for each are in that file's comments; the
summary:

| Scope | Resource | Verbs | Why |
| --- | --- | --- | --- |
| Ray namespace | `ray.io` rayclusters, rayservices, rayjobs | get, list, create, patch, delete | SSA apply, suspend/resume patch, observe, ownership-scoped list, terminate. `rayjobs` is requirement 5: an ephemeral RayJob whose cluster KubeRay removes when the job finishes |
| Ray namespace | secrets | get | Requirement 12: a metadata-only existence check (`PartialObjectMetadata`) on a cataloged Secret name before a cluster, service or job that references it is applied, so a typo is a Bifrost condition rather than `CreateContainerConfigError`. Kubernetes has no metadata-only verb, so RBAC cannot express that limit; the code path does. No list, create, patch or delete |
| Ray namespace | networkpolicies | list, create, patch, delete | Tenant default-deny / tenant-allow / per-cluster allow, plus the admin-managed-deny probe |
| Ray namespace | pods | list | Node breakdown and log-target resolution, by label |
| Ray namespace | pods/log | get | The logs tab |
| Ray namespace | events | list | The events tab |
| Cluster (`resourceNames`-scoped) | namespaces | get, patch | Pod Security Standards labels on the Ray namespace only |
| Cluster | `kueue.x-k8s.io` clusterqueues | get, list, create, patch, delete | Pool quota ledger reads plus apply/teardown |
| Cluster | `kueue.x-k8s.io` cohorts, resourceflavors, localqueues | list, create, patch, delete | Apply and label-selected teardown; LocalQueues are listed across all namespaces |

Deliberately absent: any `watch` verb (Bifrost polls — controller-runtime is
used uncached, no Manager, no informers), `get` on pods or networkpolicies
(every read is a label-selected list), cluster-wide namespace access,
`pods/exec`, and every Secrets verb but `get` (Bifrost never creates or
edits a Secret, and never reads one's data — the values reach Ray pods
through `envFrom.secretRef` and secret volumes the kubelet resolves).
`.github/workflows/test.yaml` asserts both halves — that each granted verb
is allowed, and that the absent ones are denied.

## Configuration

See [`chart/values.yaml`](chart/values.yaml); every value carries its
reasoning. The ones you will actually set:

| Value | Default | Notes |
| --- | --- | --- |
| `image.repository` / `image.tag` | `ghcr.io/brandonrc/bifrost` / chart appVersion | **Not published yet** — build from the bifrost repo's Dockerfile |
| `auth.mode` | `oidc` | `oidc` \| `local` \| `none` |
| `auth.oidc.issuer` | placeholder | Your Keycloak realm; discovery must resolve at boot or the pod fails fast |
| `auth.oidc.roles` | all empty | Group → role mappings; deny-by-default |
| `store.kind` | `sqlite` | `memory` \| `sqlite` \| `postgres`; `postgres` is the only one that supports `replicaCount > 1` |
| `ray.namespace` | release namespace | Where RayClusters land. Not `ray` |
| `nebariApp.api.hostname` | — | Required when `nebariApp.api.enabled` |
| `ui.enabled` | `false` | Dashboard; SSO config is served at runtime (`ui.sso.*`) |
| `gateway.domain` | `` (off) | Requirement 5 and the Serve half of 1/2: turns on dynamic gateway registration; provisioned clusters, running jobs and Serve endpoints answer as `<name>.<domain>` (Host-header matched). Empty leaves only the static `clusters` registry |
| `gateway.externalBase` | `` | Scheme-and-authority prefix (e.g. `https://`) Bifrost puts before that hostname in the `gateway_url` it reports. Labels responses only; requires `gateway.domain` |
| `services.perProject` | `1` | Requirements 1/2: live Ray Serve applications per project. `1` is the design (a second name is `409` until the first is deleted; the same name redeploys); the flag is rendered only when raised |

Flags the Rust predecessor had and Bifrost deliberately did not port — `--policy`,
`--audit-log`, `--metering-interval-secs`, `--demo` — have no values here.
They are gone, not renamed.

## Observability

`observability.enabled=true` renders what a Prometheus-operator stack needs to
scrape Bifrost and every Ray cluster it provisions, plus the Grafana dashboard
that reads the result:

- a `ServiceMonitor` for `GET /api/v1/metrics` — Read on the cluster target, so
  the scraper needs an identity: a local `viewer` user's PAT in the Secret named
  by `observability.api.secretName`, in the monitors' namespace;
- a `PodMonitor` for every Ray head and worker (`ray.io/is-ray-node=yes`, port
  `metrics`), relabelling `bifrost.dev/cluster-id` and `bifrost.dev/owner` onto
  every series so the dashboard slices by tenant;
- the one `NetworkPolicy` Bifrost's tenant posture does not grant — the
  scraper's namespace to `:8080` on Ray pods (without it, every Ray target times
  out);
- optionally (`observability.gateway.enabled`) the platform gateway's per-route
  request series, everything else dropped at scrape time;
- the **Bifrost platform** dashboard as a ConfigMap for the Grafana dashboards
  sidecar, its datasource uid rewritten to `observability.dashboard.datasourceUid`.

The dashboard's source of truth is `bifrost/deploy/grafana/`;
`scripts/sync-dashboard.sh` copies it into `chart/dashboards/` before a release.
The standalone form of the same wiring, as applied on grace, is in
`bifrost/deploy/observability/`.

## Known gaps

- **No published server image.** The Dockerfile exists in the bifrost repo; no
  workflow pushes it.
- **Postgres DSN is visible in the pod spec.** `bifrost serve` accepts `--db`
  only as a command-line argument — no env or file indirection — so the
  password shows up in `kubectl get pod -o yaml`. Inherited from the predecessor; needs
  a server change, not a chart change.
- **SPA client mappers.** The nebari-operator provisions the dashboard's
  public SPA client with neither an audience mapper nor a groups mapper, so
  its tokens carry `aud: account` and no `groups` and Bifrost rejects them.
  Until the operator adds them (it already does for its device-flow client),
  add an `oidc-audience-mapper` (included client = the SPA client id) and an
  `oidc-group-membership-mapper` (claim `groups`, full path off) to the
  client by hand. The runtime config itself (`/config.json`) is in place.
- **Kueue must serve `v1beta2`.** Bifrost probes for
  `kueue.x-k8s.io/v1beta2` specifically. Against an older Kueue the probe
  fails and the pool reconciler never starts, with one INFO line to say so.
  Kueue v0.19.2 works; v0.14.2 does not. The chart's RBAC is
  version-independent, so this is a cluster prerequisite, not a chart knob.
- **No docs site.** `docs_site: false` in `pack-metadata.yaml` — this README
  is the documentation for now.

## License

[Apache-2.0](LICENSE).
