SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

CHART        := charts/cube-stack
RELEASE      ?= cube
NAMESPACE    ?= cube
VALUES       ?= $(CHART)/values.yaml
OVERLAY      ?=
CUBE_VERSION ?= v1.6.41
IMAGE        ?= cubejs/cube
IMAGE_TAG    ?= $(CUBE_VERSION)
KIND_CLUSTER ?= cube

HELM_FILES = -f $(VALUES) $(if $(OVERLAY),-f $(OVERLAY),)

##@ Helm

.PHONY: deps lint template render-prod render-dev install upgrade uninstall test status

deps:           ## Pull chart dependencies
	helm dependency update $(CHART)

lint: deps      ## helm lint with default + every overlay
	helm lint $(CHART)
	helm lint $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-prod.yaml
	helm lint $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-dev.yaml
	helm lint $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-quickstart.yaml

template: deps  ## Render chart with $(VALUES) (and optional $(OVERLAY))
	helm template $(RELEASE) $(CHART) $(HELM_FILES) --namespace $(NAMESPACE)

render-prod: deps ## Render with the production overlay
	helm template $(RELEASE) $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-prod.yaml --namespace $(NAMESPACE) > rendered-prod.yaml
	@echo "→ rendered-prod.yaml"

render-dev: deps ## Render with the dev overlay
	helm template $(RELEASE) $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-dev.yaml --namespace $(NAMESPACE) > rendered-dev.yaml
	@echo "→ rendered-dev.yaml"

render-quickstart: deps ## Render with the quickstart overlay (zero external deps)
	helm template $(RELEASE) $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values-quickstart.yaml --namespace $(NAMESPACE) > rendered-quickstart.yaml
	@echo "→ rendered-quickstart.yaml"

quickstart: deps ## Install in quickstart mode (zero external deps)
	helm upgrade --install $(RELEASE) $(CHART) \
	  -f $(CHART)/values.yaml -f $(CHART)/values-quickstart.yaml \
	  --namespace $(NAMESPACE) --create-namespace \
	  --wait --timeout 5m
	@echo
	@echo "Open the playground:"
	@echo "  kubectl -n $(NAMESPACE) port-forward svc/$(RELEASE)-cube-stack-api 4000"
	@echo "  open http://localhost:4000"

install: deps   ## helm upgrade --install
	helm upgrade --install $(RELEASE) $(CHART) $(HELM_FILES) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --wait --timeout 10m

upgrade: install ## Alias for install (helm upgrade --install)

uninstall:      ## helm uninstall + delete namespace
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	-kubectl delete ns $(NAMESPACE) --wait=false

test:           ## helm test
	helm test $(RELEASE) -n $(NAMESPACE)

status:         ## kubectl status of every component
	kubectl -n $(NAMESPACE) get all,pdb,hpa,ingress,networkpolicy,servicemonitor 2>/dev/null

##@ Validation

.PHONY: kubeconform kubelinter validate

kubeconform: deps  ## Validate all rendered manifests against k8s schemas
	@command -v kubeconform >/dev/null || { echo "install kubeconform first"; exit 1; }
	@for vf in values-prod.yaml values-dev.yaml values-quickstart.yaml; do \
	  echo "→ $$vf"; \
	  helm template $(RELEASE) $(CHART) -f $(CHART)/values.yaml -f $(CHART)/$$vf --namespace $(NAMESPACE) \
	    | kubeconform -strict -ignore-missing-schemas -summary; \
	done

kubelinter: deps   ## Run kube-linter against rendered manifests
	@command -v kube-linter >/dev/null || { echo "install kube-linter first"; exit 1; }
	helm template $(RELEASE) $(CHART) $(HELM_FILES) --namespace $(NAMESPACE) | kube-linter lint -

validate: lint kubeconform  ## lint + kubeconform

##@ Docker

.PHONY: docker-build docker-push docker-test

docker-build:  ## Build local custom Cube image
	docker build -t $(IMAGE):$(IMAGE_TAG) \
	  --build-arg CUBE_VERSION=$(CUBE_VERSION) \
	  -f docker/Dockerfile docker

docker-push: docker-build ## Push to registry (requires docker login)
	docker push $(IMAGE):$(IMAGE_TAG)

docker-test:  ## Smoke-test the image locally
	docker run --rm --name cube-smoke -p 4000:4000 \
	  -e CUBEJS_DEV_MODE=true \
	  -e CUBEJS_DB_TYPE=postgres \
	  -e CUBEJS_API_SECRET=$$(openssl rand -hex 32) \
	  $(IMAGE):$(IMAGE_TAG)

##@ Local kind cluster

.PHONY: kind-up kind-down kind-deploy kind-deploy-postgres

kind-up:       ## Create local kind cluster
	@command -v kind >/dev/null || { echo "install kind first"; exit 1; }
	kind create cluster --name $(KIND_CLUSTER)

kind-down:     ## Tear down kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

kind-deploy-postgres: ## Bring up an in-cluster Postgres for the dev overlay
	kubectl apply -f examples/postgres-dev.yaml
	kubectl wait --for=condition=ready pod/postgres -n default --timeout=120s

kind-deploy: kind-deploy-postgres deps ## Full dev install on kind
	helm upgrade --install $(RELEASE) $(CHART) \
	  -f $(CHART)/values.yaml -f $(CHART)/values-dev.yaml \
	  --namespace $(NAMESPACE) --create-namespace \
	  --wait --timeout 10m

##@ HA fork — Cube Store with Raft replication

# Build the agriev/cube fork's cubestored image. Defaults assume
# the fork is at $HOME/workspace/cube; override CUBE_REPO for a
# different path.
CUBE_REPO     ?= $(HOME)/workspace/cube
CUBESTORE_HA_TAG ?= dev

.PHONY: ha-image ha-deploy ha-verify ha-down

ha-image:        ## Build the HA fork's cubestore image (cubestore-ha:dev)
	cd $(CUBE_REPO)/rust && \
	  docker build -t cubestore-ha:$(CUBESTORE_HA_TAG) \
	    --build-arg WITH_AVX2=0 \
	    -f cubestore/Dockerfile .

ha-deploy:       ## Deploy 3-router HA cluster to local k8s (namespace cube-ha)
	@if kubectl describe node docker-desktop 2>/dev/null | grep -q "DiskPressure     True"; then \
	  echo "ERROR: kubectl reports DiskPressure on docker-desktop node. kubelet will evict pods on schedule."; \
	  echo "       Free disk inside the Docker VM (Settings → Resources → Disk image size, then \"Apply & restart\")"; \
	  echo "       or run \`docker system prune -a\` (destructive — wipes all Docker artifacts)."; \
	  exit 1; \
	fi
	helm upgrade --install cube-ha $(CHART) \
	  -f $(CHART)/values.yaml -f $(CHART)/values-ha-test.yaml \
	  --namespace cube-ha --create-namespace \
	  --wait --timeout 5m

ha-verify:       ## Smoke-test the HA cluster (election + failover)
	NS=cube-ha REL=cube-ha scripts/ha-verify.sh

ha-down:         ## Tear down the HA test deployment + namespace
	helm uninstall cube-ha -n cube-ha 2>/dev/null || true
	kubectl delete namespace cube-ha --ignore-not-found

##@ Helpers

.PHONY: help

help:  ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z0-9_.-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
