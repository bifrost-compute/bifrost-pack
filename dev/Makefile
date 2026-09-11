# Local development Makefile for bifrost-pack
#
# Creates a kind cluster with the full Nebari infrastructure stack (MetalLB,
# Envoy Gateway, cert-manager, Keycloak, nebari-operator) plus the KubeRay
# operator, and deploys Bifrost with a NebariApp.
#
# Prerequisites: docker, kind, helm, kubectl, git
#
# Usage:
#   make up             Deploy Bifrost with a NebariApp (needs the operator)
#   make up-standalone  Deploy Bifrost with local auth, no operator, no gateway
#   make update-hosts   Update /etc/hosts with NebariApp hostnames
#   make down           Delete the kind cluster
#
# The chart's image default (ghcr.io/bifrost-compute/bifrost) is NOT published yet.
# Point IMAGE_REPO/IMAGE_TAG at an image you built from the bifrost repo's
# Dockerfile, or `kind load docker-image` it into the cluster first:
#   make up IMAGE_REPO=bifrost IMAGE_TAG=dev

CHART_DIR      := ../chart
CLUSTER_NAME   := bifrost-dev
RELEASE        := bifrost
NAMESPACE      := bifrost
# NOT `ray`: on a Nebari cluster that namespace belongs to rayserve-pack's
# `shared` release, and the chart refuses it. Kept separate from NAMESPACE
# here so the cross-namespace control-plane labelling path gets exercised.
RAY_NAMESPACE  := bifrost-clusters
HOSTNAME       := bifrost.nebari.local
UI_HOSTNAME    := bifrost-dashboard.nebari.local
IMAGE_REPO     := ghcr.io/bifrost-compute/bifrost
IMAGE_TAG      := latest
KUBERAY_VERSION := 1.4.0
CACHE_DIR      := .cache
OPERATOR_REPO  := $(CACHE_DIR)/nebari-operator
OPERATOR_REF   := main

# MetalLB IP pool configuration template.
define METALLB_POOL
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - METALLB_BASE_IP.255.200-METALLB_BASE_IP.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - kind-pool
endef
export METALLB_POOL

.PHONY: up up-standalone down cluster update-hosts lint

# --------------------------------------------------------------------------
# lint - what CI runs, locally
# --------------------------------------------------------------------------
lint:
	helm dependency update $(CHART_DIR)
	helm lint $(CHART_DIR)
	helm template test $(CHART_DIR) >/dev/null
	helm template test $(CHART_DIR) \
		--set nebariApp.api.enabled=true \
		--set nebariApp.api.hostname=$(HOSTNAME) >/dev/null
	@echo "lint OK"

# --------------------------------------------------------------------------
# cluster - kind + full Nebari infrastructure + KubeRay
# --------------------------------------------------------------------------
cluster:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster '$(CLUSTER_NAME)' already exists, skipping setup"; \
	else \
		$(MAKE) _cluster-create; \
	fi

_cluster-create: _clone-operator _kind-create _metallb _services _keycloak-setup _operator _kuberay _namespaces
	@echo ""
	@echo "=========================================="
	@echo "Cluster setup complete!"
	@echo "=========================================="
	@echo ""
	@echo "Run 'make up' to deploy Bifrost with a NebariApp."

_clone-operator:
	@if [ ! -d "$(OPERATOR_REPO)" ]; then \
		echo "Cloning nebari-operator ($(OPERATOR_REF)) into $(OPERATOR_REPO)..."; \
		mkdir -p $(CACHE_DIR); \
		git clone --depth 1 --branch $(OPERATOR_REF) \
			https://github.com/nebari-dev/nebari-operator.git $(OPERATOR_REPO); \
	else \
		echo "nebari-operator already cloned"; \
	fi

_kind-create:
	@echo "Creating kind cluster: $(CLUSTER_NAME)"
	kind create cluster --name $(CLUSTER_NAME)

_metallb:
	@echo "Installing MetalLB..."
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml 2>&1 | grep -v "unrecognized format"
	kubectl wait --namespace metallb-system \
		--for=condition=available deployment/controller \
		--timeout=90s
	kubectl wait --namespace metallb-system \
		--for=jsonpath='{.status.numberReady}'=1 \
		daemonset/speaker \
		--timeout=90s
	@KIND_NET_CIDR=$$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | grep '\.' | head -n1); \
	BASE_IP=$$(echo $${KIND_NET_CIDR} | awk -F. '{print $$1"."$$2}'); \
	echo "MetalLB IP pool: $${BASE_IP}.255.200-$${BASE_IP}.255.250"; \
	echo "$$METALLB_POOL" | sed "s/METALLB_BASE_IP/$${BASE_IP}/g" | kubectl apply -f -
	@echo "MetalLB installed"

_services:
	@echo "Installing foundational services (Envoy Gateway, cert-manager, Keycloak, Gateway, TLS)..."
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/services/install.sh

_keycloak-setup:
	@echo "Setting up Keycloak realm..."
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/services/keycloak/setup.sh

_operator:
	@echo "Installing nebari-operator..."
	kubectl apply -f https://github.com/nebari-dev/nebari-operator/releases/download/v0.1.0-alpha.5/install.yaml
	kubectl wait --for=condition=available deployment/nebari-operator-controller-manager \
		-n nebari-operator-system --timeout=120s
	@echo "nebari-operator is running"

# The chart deliberately does NOT install KubeRay (kuberay-operator.enabled
# defaults to false). One operator, installed once, cluster-wide — the same
# version bifrost's own kind-e2e workflow uses.
_kuberay:
	@echo "Installing kuberay-operator $(KUBERAY_VERSION)..."
	helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null
	helm repo update >/dev/null
	helm upgrade --install kuberay-operator kuberay/kuberay-operator \
		--version $(KUBERAY_VERSION) --wait --timeout 5m
	kubectl wait --for=condition=Available deploy/kuberay-operator --timeout=180s

# Three labels, each load-bearing:
#   nebari.dev/managed          - without it the operator ignores every
#                                 NebariApp in the namespace, silently
#   bifrost.dev/control-plane   - Bifrost's own tenant-allow NetworkPolicy
#                                 admits control-plane pods to Ray heads only
#                                 from a namespace carrying this
#   (ray namespace)             - must exist before Bifrost applies its PSS
#                                 labels to it
_namespaces:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace $(RAY_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl label namespace $(NAMESPACE) nebari.dev/managed=true --overwrite
	kubectl label namespace $(NAMESPACE) bifrost.dev/control-plane=true --overwrite

# --------------------------------------------------------------------------
# up - deploy Bifrost with a NebariApp
# --------------------------------------------------------------------------
up: cluster
	helm dependency update $(CHART_DIR)
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
		--namespace $(NAMESPACE) \
		--set image.repository=$(IMAGE_REPO) \
		--set image.tag=$(IMAGE_TAG) \
		--set ray.namespace=$(RAY_NAMESPACE) \
		--set nebariApp.api.enabled=true \
		--set nebariApp.api.hostname=$(HOSTNAME) \
		--wait --timeout 5m
	kubectl wait --for=condition=Ready nebariapp/$(RELEASE) -n $(NAMESPACE) --timeout=180s
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/networking/update-hosts.sh
	@echo ""
	@echo "Bifrost deployed with a NebariApp."
	@echo "  API: https://$(HOSTNAME)/healthz"
	@echo ""
	@echo "Gateway OIDC enforcement is OFF by design — Bifrost validates the"
	@echo "bearer token itself. Get one with: bifrost login --issuer <realm>"

# --------------------------------------------------------------------------
# up-ui - the dashboard, which nothing else here starts
# --------------------------------------------------------------------------
# `ui.enabled` defaults to false, and neither `up` nor `up-standalone` passes
# it (UI_HOSTNAME was defined but never referenced), so the dashboard
# container was never started by any conventional run of this Makefile. That
# is how an image/chart incompatibility reached a live cluster: stock nginx
# runs as root and chowns /var/cache/nginx at startup, needing CAP_CHOWN,
# which ui.yaml's `capabilities: drop: ["ALL"]` removes — CrashLoopBackOff,
# with every port, label and template correct.
#
# So this target exists to start it and assert it comes up. It waits for Ready
# rather than just applying, because that failure is only visible at runtime.
up-ui: up
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
		--namespace $(NAMESPACE) \
		--reuse-values \
		--set ui.enabled=true \
		--set nebariApp.ui.enabled=true \
		--set nebariApp.ui.hostname=$(UI_HOSTNAME) \
		--wait --timeout 5m
	kubectl wait --for=condition=Ready pod \
		-l app.kubernetes.io/component=dashboard \
		-n $(NAMESPACE) --timeout=180s
	@echo ""
	@echo "Dashboard deployed and Ready."
	@echo "  UI:  https://$(UI_HOSTNAME)/"
	@echo ""

# --------------------------------------------------------------------------
# up-standalone - no operator, no gateway, local (IdP-free) auth
# --------------------------------------------------------------------------
up-standalone:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Creating kind cluster: $(CLUSTER_NAME)"; \
		kind create cluster --name $(CLUSTER_NAME); \
		$(MAKE) _kuberay; \
	fi
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace $(RAY_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl label namespace $(NAMESPACE) bifrost.dev/control-plane=true --overwrite
	helm dependency update $(CHART_DIR)
	helm upgrade --install $(RELEASE) $(CHART_DIR) \
		--namespace $(NAMESPACE) \
		--set image.repository=$(IMAGE_REPO) \
		--set image.tag=$(IMAGE_TAG) \
		--set auth.mode=local \
		--set ray.namespace=$(RAY_NAMESPACE) \
		--wait --timeout 5m
	@echo ""
	@echo "Bifrost deployed (standalone, local auth)."
	@echo ""
	@echo "  kubectl port-forward -n $(NAMESPACE) svc/$(RELEASE) 8484:8484"
	@echo "  curl -s localhost:8484/healthz"
	@echo ""
	@echo "Bootstrap admin password:"
	@echo "  kubectl exec -n $(NAMESPACE) deploy/$(RELEASE) -- cat /data/local-admin-password"

# --------------------------------------------------------------------------
# update-hosts - update /etc/hosts with all NebariApp hostnames
# --------------------------------------------------------------------------
update-hosts:
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/networking/update-hosts.sh

# --------------------------------------------------------------------------
# down - delete the kind cluster
# --------------------------------------------------------------------------
down:
	kind delete cluster --name $(CLUSTER_NAME)
