# =============================================================================
# OpenPanel DevOps — Makefile
# =============================================================================
#
# Uso completo desde cero:
#   make all GITHUB_USER=rubenlopsol GITHUB_TOKEN=gho_xxx
#
# Requisitos previos:
#   - minikube, kubectl, docker, argocd CLI, kubeseal, velero CLI instalados
#
# =============================================================================

# ----------------------------------------------------------------------------
# Variables — sobreescribibles desde la línea de comandos
# ----------------------------------------------------------------------------
GITHUB_USER    ?= rubenlopsol
REPO_NAME      ?= proyecto-final-devops
GITHUB_TOKEN   ?=
PROFILE        ?= openpanel
NAMESPACE      ?= openpanel
SCRIPTS_DIR    = ./scripts

# gh CLI usa GH_TOKEN para autenticarse sin login interactivo
export GH_TOKEN = $(GITHUB_TOKEN)

.PHONY: help all setup-github docker-login cluster dns argocd argocd-apps \
        sealed-secrets reseal-secrets app observability backup status stop \
        restart destroy blue-green backup-run logs open clean clean-all

# ----------------------------------------------------------------------------
# Default — muestra ayuda
# ----------------------------------------------------------------------------
help:
	@echo ""
	@echo "  OpenPanel DevOps — Comandos disponibles"
	@echo ""
	@echo "  Instalación completa (desde cero):"
	@echo "    make all GITHUB_USER=<user> GITHUB_TOKEN=<token>"
	@echo ""
	@echo "  Paso a paso:"
	@echo "    make setup-github     Crea el repo en GitHub y configura CI/CD"
	@echo "    make docker-login     Login en GHCR"
	@echo "    make cluster          Levanta Minikube, namespaces y configura /etc/hosts"
	@echo "    make dns              Refresca /etc/hosts (útil si Minikube cambia de IP)"
	@echo "    make argocd           Instala ArgoCD en el cluster"
	@echo "    make sealed-secrets   Instala el controller de Sealed Secrets y re-sella los secrets"
	@echo "    make reseal-secrets   Re-sella todos los secrets con la clave del cluster actual"
	@echo "    make argocd-apps      Aplica AppProject y Applications en ArgoCD"
	@echo "    make app              Despliega la aplicación via kustomize (manual)"
	@echo "    make observability    Despliega Prometheus, Grafana, Loki, Tempo (manual)"
	@echo "    make backup           Despliega MinIO (manual)"
	@echo ""
	@echo "  Operaciones:"
	@echo "    make open             Abre todas las UIs en el navegador"
	@echo "    make blue-green       Ejecuta el switch Blue-Green de la API"
	@echo "    make backup-run       Crea un backup manual con Velero"
	@echo "    make logs             Muestra logs de los pods de la app"
	@echo "    make status           Estado general del cluster"
	@echo ""
	@echo "  Cluster:"
	@echo "    make stop             Para Minikube"
	@echo "    make restart          Para y vuelve a arrancar Minikube"
	@echo "    make destroy          Elimina el cluster completamente"
	@echo ""
	@echo "  Limpieza:"
	@echo "    make clean            Para y elimina Minikube + limpia /etc/hosts"
	@echo "    make clean-all        clean + elimina credentials y repos de Helm"
	@echo ""
	@echo "  Variables:"
	@echo "    GITHUB_USER    Usuario de GitHub (default: $(GITHUB_USER))"
	@echo "    REPO_NAME      Nombre del repositorio (default: $(REPO_NAME))"
	@echo "    GITHUB_TOKEN   Token OAuth de GitHub (gh CLI + docker login GHCR)"
	@echo "    PROFILE        Perfil de Minikube (default: $(PROFILE))"
	@echo "    NAMESPACE      Namespace principal (default: $(NAMESPACE))"
	@echo ""

# ----------------------------------------------------------------------------
# Todo de una vez
# ----------------------------------------------------------------------------
all: setup-github docker-login cluster argocd sealed-secrets argocd-apps open
	@echo ""
	@echo "=========================================="
	@echo "  Instalación completa finalizada"
	@echo "  ArgoCD desplegará la app automáticamente"
	@echo ""
	@echo "  Accesos:"
	@echo "    App:        http://openpanel.local"
	@echo "    ArgoCD:     http://argocd.local"
	@echo "    Grafana:    http://grafana.local"
	@echo "    Prometheus: http://prometheus.local"
	@echo "=========================================="
	@echo ""

# ----------------------------------------------------------------------------
# GitHub — setup completo del repositorio
# ----------------------------------------------------------------------------
setup-github:
	@echo "=== Configurando repositorio GitHub ==="
	@if [ -z "$(GITHUB_USER)" ]; then echo "ERROR: GITHUB_USER es obligatorio"; exit 1; fi
	@if [ -z "$(GITHUB_TOKEN)" ]; then echo "ERROR: GITHUB_TOKEN es obligatorio"; exit 1; fi

	@# Inicializar git si no está inicializado
	@if [ ! -d ".git" ]; then \
		git init; \
		git add .gitignore; \
		git commit -m "Initial commit: project structure"; \
	fi

	@# Reemplazar placeholder GITHUB_USER en manifiestos
	@echo "--- Reemplazando GITHUB_USER por $(GITHUB_USER) en manifiestos ---"
	@grep -rl "GITHUB_USER" k8s/ .github/ 2>/dev/null | xargs sed -i "s/GITHUB_USER/$(GITHUB_USER)/g" || true

	@# Crear repo en GitHub si no existe
	@echo "--- Creando repositorio en GitHub ---"
	@gh repo create $(GITHUB_USER)/$(REPO_NAME) --public --source=. --push 2>/dev/null || \
		echo "El repo ya existe, continuando..."

	@# Configurar permisos de escritura para GitHub Actions (necesario para el CD)
	@echo "--- Configurando permisos de GitHub Actions ---"
	@gh api -X PUT repos/$(GITHUB_USER)/$(REPO_NAME)/actions/permissions/workflow \
		-f default_workflow_permissions=write \
		-F can_approve_pull_request_reviews=false

	@# Crear variable REGISTRY_OWNER
	@echo "--- Creando variable REGISTRY_OWNER ---"
	@gh variable set REGISTRY_OWNER \
		--repo $(GITHUB_USER)/$(REPO_NAME) \
		--body "$(shell echo $(GITHUB_USER) | tr '[:upper:]' '[:lower:]')"

	@# Commit y push de toda la estructura
	@echo "--- Subiendo estructura del proyecto ---"
	@git add k8s/ .github/ scripts/ Makefile credentials-velero.example
	@git diff --staged --quiet || git commit -m "feat: add k8s manifests, CI/CD workflows, scripts and Makefile"
	@git push -u origin master 2>/dev/null || git push -u origin main 2>/dev/null || true

	@echo "=== Repositorio GitHub configurado ==="

# ----------------------------------------------------------------------------
# Docker — login en GHCR con el mismo token de GitHub
# ----------------------------------------------------------------------------
docker-login:
	@echo "=== Login en GHCR ==="
	@if [ -z "$(GITHUB_TOKEN)" ]; then echo "ERROR: GITHUB_TOKEN es obligatorio"; exit 1; fi
	@echo $(GITHUB_TOKEN) | docker login ghcr.io -u $(GITHUB_USER) --password-stdin
	@echo "=== Login correcto ==="

# ----------------------------------------------------------------------------
# Cluster
# ----------------------------------------------------------------------------
cluster:
	$(SCRIPTS_DIR)/setup-minikube.sh

dns:
	@if grep -q "openpanel.local" /etc/hosts; then \
		echo "DNS ya configurado en /etc/hosts — actualizando IP..."; \
		sudo sed -i '/openpanel.local/d' /etc/hosts; \
	fi
	@echo "$(shell minikube ip -p $(PROFILE)) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
		| sudo tee -a /etc/hosts
	@echo "DNS configurado. Verifica con: grep openpanel.local /etc/hosts"

stop:
	minikube stop -p $(PROFILE)

restart:
	minikube stop -p $(PROFILE) || true
	minikube start -p $(PROFILE)

destroy:
	minikube delete -p $(PROFILE)

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
# Stops and deletes the Minikube cluster, removes DNS entries from /etc/hosts
clean:
	@echo "=== Stopping and deleting Minikube cluster '$(PROFILE)' ==="
	@minikube stop -p $(PROFILE) 2>/dev/null || true
	@minikube delete -p $(PROFILE) 2>/dev/null || true
	@echo "=== Removing DNS entries from /etc/hosts ==="
	@sudo sed -i '/openpanel\.local/d' /etc/hosts 2>/dev/null || true
	@echo "=== Cluster removed and DNS cleaned up ==="

# Runs 'clean' and also removes generated credentials and Helm repos
clean-all: clean
	@echo "=== Removing Velero credentials file ==="
	@rm -f credentials-velero
	@echo "=== Removing Helm repos added by this project ==="
	@helm repo remove argo 2>/dev/null || true
	@helm repo remove sealed-secrets 2>/dev/null || true
	@echo "=== Full cleanup complete ==="

# ----------------------------------------------------------------------------
# ArgoCD
# ----------------------------------------------------------------------------
argocd:
	$(SCRIPTS_DIR)/install-argocd.sh

argocd-apps:
	kubectl apply -f k8s/argocd/projects/
	kubectl apply -f k8s/argocd/applications/
	@echo "ArgoCD sincronizará el cluster automáticamente."

# ----------------------------------------------------------------------------
# Sealed Secrets
# ----------------------------------------------------------------------------
sealed-secrets:
	helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
	helm repo update
	helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
		--namespace sealed-secrets --create-namespace
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets \
		-n sealed-secrets --timeout=120s
	@$(MAKE) reseal-secrets
	kubectl apply -f k8s/argocd/sealed-secrets/

# Re-seal all secrets using the current cluster's key.
# Required whenever you start a fresh Minikube cluster because each cluster
# generates a new Sealed Secrets key pair and cannot decrypt secrets sealed
# by a previous cluster.
#
# Usage:
#   make reseal-secrets \
#     POSTGRES_PASSWORD=xxx \
#     REDIS_PASSWORD=xxx \
#     CLICKHOUSE_PASSWORD=xxx \
#     API_SECRET=xxx \
#     GRAFANA_PASSWORD=xxx \
#     MINIO_PASSWORD=xxx
#
# Sensible defaults are provided so `make all` works out of the box for
# local development. Override them for production.
POSTGRES_USER      ?= postgres
POSTGRES_PASSWORD  ?= postgres
REDIS_PASSWORD     ?= redis
CLICKHOUSE_USER    ?= clickhouse
CLICKHOUSE_PASSWORD ?= clickhouse
API_SECRET         ?= $(shell openssl rand -hex 32)
GRAFANA_USER       ?= admin
GRAFANA_PASSWORD   ?= admin
MINIO_USER         ?= minio
MINIO_PASSWORD     ?= minio123

reseal-secrets:
	@echo "=== Re-sealing secrets with current cluster key ==="
	@kubeseal --fetch-cert \
		--controller-namespace sealed-secrets \
		--controller-name sealed-secrets \
		> /tmp/sealed-secrets-cert.pem

	@# postgres-credentials
	@kubectl create secret generic postgres-credentials \
		--from-literal=POSTGRES_USER=$(POSTGRES_USER) \
		--from-literal=POSTGRES_PASSWORD=$(POSTGRES_PASSWORD) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		> k8s/argocd/sealed-secrets/postgres-credentials.yaml

	@# redis-credentials
	@kubectl create secret generic redis-credentials \
		--from-literal=REDIS_PASSWORD=$(REDIS_PASSWORD) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		> k8s/argocd/sealed-secrets/redis-credentials.yaml

	@# clickhouse-credentials
	@kubectl create secret generic clickhouse-credentials \
		--from-literal=CLICKHOUSE_USER=$(CLICKHOUSE_USER) \
		--from-literal=CLICKHOUSE_PASSWORD=$(CLICKHOUSE_PASSWORD) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		> k8s/argocd/sealed-secrets/clickhouse-credentials.yaml

	@# openpanel-secrets (composite — built from individual values)
	@# DATABASE_URL_DIRECT is required by Prisma schema; same as DATABASE_URL for local single-node
	@kubectl create secret generic openpanel-secrets \
		--from-literal=DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres.openpanel.svc.cluster.local:5432/openpanel \
		--from-literal=DATABASE_URL_DIRECT=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres.openpanel.svc.cluster.local:5432/openpanel \
		--from-literal=CLICKHOUSE_URL=http://$(CLICKHOUSE_USER):$(CLICKHOUSE_PASSWORD)@clickhouse.openpanel.svc.cluster.local:8123 \
		--from-literal=REDIS_URL=redis://:$(REDIS_PASSWORD)@redis.openpanel.svc.cluster.local:6379 \
		--from-literal=API_SECRET=$(API_SECRET) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		> k8s/argocd/sealed-secrets/openpanel-secrets.yaml

	@# grafana-admin-credentials
	@kubectl create secret generic grafana-admin-credentials \
		--from-literal=admin-user=$(GRAFANA_USER) \
		--from-literal=admin-password=$(GRAFANA_PASSWORD) \
		--namespace observability --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		> k8s/argocd/sealed-secrets/grafana-admin-credentials.yaml

	@# minio-credentials
	@kubectl create secret generic minio-credentials \
		--from-literal=MINIO_ROOT_USER=$(MINIO_USER) \
		--from-literal=MINIO_ROOT_PASSWORD=$(MINIO_PASSWORD) \
		--namespace backup --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		> k8s/argocd/sealed-secrets/minio-credentials.yaml

	@rm -f /tmp/sealed-secrets-cert.pem
	@echo "=== All secrets re-sealed — ready to apply ==="

# ----------------------------------------------------------------------------
# Despliegue manual (alternativa a ArgoCD)
# ----------------------------------------------------------------------------
app:
	kubectl apply -k k8s/overlays/local

observability:
	kubectl apply -f k8s/argocd/applications/observability-prometheus-app.yaml
	kubectl apply -f k8s/argocd/applications/observability-loki-app.yaml
	kubectl apply -f k8s/argocd/applications/observability-promtail-app.yaml
	kubectl apply -f k8s/argocd/applications/observability-tempo-app.yaml

backup:
	kubectl apply -k k8s/base/backup/

# ----------------------------------------------------------------------------
# Operaciones
# ----------------------------------------------------------------------------
blue-green:
	$(SCRIPTS_DIR)/blue-green-switch.sh

backup-run:
	$(SCRIPTS_DIR)/backup-restore.sh backup $(NAMESPACE)

logs:
	kubectl logs -n $(NAMESPACE) -l app=openpanel-api --tail=100 -f

# ----------------------------------------------------------------------------
# Estado
# ----------------------------------------------------------------------------
status:
	@echo ""
	@echo "=== Cluster ==="
	@minikube status -p $(PROFILE) || true
	@echo ""
	@echo "=== Namespaces ==="
	@kubectl get namespaces
	@echo ""
	@echo "=== Pods [openpanel] ==="
	@kubectl get pods -n $(NAMESPACE)
	@echo ""
	@echo "=== Pods [observability] ==="
	@kubectl get pods -n observability
	@echo ""
	@echo "=== Pods [backup] ==="
	@kubectl get pods -n backup
	@echo ""
	@echo "=== ArgoCD Apps ==="
	@kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD no instalado"
	@echo ""

# ----------------------------------------------------------------------------
# Abrir UIs en el navegador
# ----------------------------------------------------------------------------
open:
	@echo "=== Abriendo servicios en el navegador ==="
	@xdg-open http://openpanel.local &
	@xdg-open http://api.openpanel.local &
	@xdg-open http://argocd.local &
	@xdg-open http://grafana.local &
	@xdg-open http://prometheus.local &
