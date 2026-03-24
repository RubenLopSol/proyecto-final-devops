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
        sealed-secrets app observability backup status stop destroy \
        blue-green backup-run logs open

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
	@echo "    make cluster          Levanta Minikube con addons y namespaces"
	@echo "    make dns              Configura /etc/hosts con las IPs del cluster"
	@echo "    make argocd           Instala ArgoCD en el cluster"
	@echo "    make sealed-secrets   Instala el controller de Sealed Secrets"
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
	@echo "    make destroy          Elimina el cluster completamente"
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
all: setup-github docker-login cluster dns argocd sealed-secrets argocd-apps open
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

destroy:
	minikube delete -p $(PROFILE)

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
	helm install sealed-secrets sealed-secrets/sealed-secrets \
		--namespace sealed-secrets --create-namespace
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets \
		-n sealed-secrets --timeout=120s
	kubectl apply -f k8s/argocd/sealed-secrets/

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
