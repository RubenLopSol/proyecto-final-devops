# =============================================================================
# OpenPanel DevOps — Makefile
# =============================================================================
SHELL := /bin/bash
#
# Full install from scratch:
#   make all GITHUB_USER=rubenlopsol GITHUB_TOKEN=gho_xxx
#
# Or load credentials from .secrets file (copy from .secrets.example):
#   cp .secrets.example .secrets   # fill in your values
#   make all GITHUB_USER=rubenlopsol
#
# Prerequisites:
#   minikube, kubectl, docker, argocd CLI, kubeseal, velero CLI
#
# =============================================================================

# ----------------------------------------------------------------------------
# Colors and output helpers — same style as scripts/setup-minikube.sh
# ----------------------------------------------------------------------------
BOLD  = \033[1m
RESET = \033[0m
RED   = \033[0;31m
GREEN = \033[0;32m
YELLOW= \033[1;33m
CYAN  = \033[0;36m

# header  — section title (cyan bold)
# step    — sub-step inside a section (yellow)
# success — positive outcome (green bold)
# info    — plain indented note
header  = @echo -e "\n$(CYAN)$(BOLD)=== $(1) ===$(RESET)"
step    = @echo -e "$(YELLOW)--- $(1) ---$(RESET)"
success = @echo -e "$(GREEN)$(BOLD)✔ $(1)$(RESET)"
info    = @echo -e "  $(1)"

# ----------------------------------------------------------------------------
# Secrets file — load from .secrets if it exists
#
# Format (one variable per line):
#   GITHUB_TOKEN=ghp_xxx
#   POSTGRES_PASSWORD=my-strong-password
#
# .secrets is git-ignored — never committed.
# Template: .secrets.example
# ----------------------------------------------------------------------------
SECRETS_FILE ?= .secrets
-include $(SECRETS_FILE)
export

# gh CLI requires GH_TOKEN (not GITHUB_TOKEN) for non-interactive auth.
# Uses lazy evaluation (=) so GITHUB_TOKEN is read after .secrets is loaded.
export GH_TOKEN = $(GITHUB_TOKEN)

# ----------------------------------------------------------------------------
# PATH — ensure user-local binaries (terraform, kubectl, etc.) are found
# Covers: ~/.local/bin (Linux pip/manual installs), /usr/local/bin (brew/manual)
# ----------------------------------------------------------------------------
export PATH := $(HOME)/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$(PATH)

# Force Terraform (Go runtime) to use IPv4 when reaching registry.terraform.io.
# Without this, Go tries IPv6 first which is unreachable on most local setups.
export GODEBUG := netdns=go preferIPv4=1

# ----------------------------------------------------------------------------
# Variables — all overridable from the command line or .secrets file
# ----------------------------------------------------------------------------

# --- GitHub / Registry ------------------------------------------------------
GITHUB_USER    ?= rubenlopsol
REPO_NAME      ?= proyecto-final-devops
GITHUB_TOKEN   ?=

# --- Cluster / Minikube -----------------------------------------------------
PROFILE        ?= devops-cluster
SCRIPTS_DIR     = ./scripts

# --- Operations shorthand ---------------------------------------------------
# Used only by: make logs, make status, make backup-run.
# Namespaces themselves are declared in base/namespaces/namespaces.yaml
# and created by `make cluster` — this variable is just a CLI convenience.
APP_NAMESPACE  ?= openpanel

# --- Deployment environment -------------------------------------------------
# Controls which overlay is used for sealed secrets and deployments.
# Values: staging (default) | prod
ENV            ?= staging

# --- Sealed Secrets — file path (derived from ENV) --------------------------
SEALED_SECRETS_FILE = k8s/infrastructure/overlays/$(ENV)/sealed-secrets/secrets.yaml

# --- Sealed Secrets — credentials -------------------------------------------
# Defaults are intentionally weak for local dev (make all works out of the box).
# Override via .secrets file or command line for staging/prod deployments.
POSTGRES_USER       ?= postgres
POSTGRES_PASSWORD   ?= postgres
REDIS_PASSWORD      ?= redis
CLICKHOUSE_USER     ?= clickhouse
CLICKHOUSE_PASSWORD ?= clickhouse
API_SECRET          ?= $(shell openssl rand -hex 32)
GRAFANA_USER        ?= admin
GRAFANA_PASSWORD    ?= admin
MINIO_USER          ?= minio
MINIO_PASSWORD      ?= minio123

# --- AWS / LocalStack -------------------------------------------------------
# For real AWS, remove --endpoint-url from backup-sealing-key / restore-sealing-key.
LOCALSTACK_ENDPOINT       ?= http://localhost:4566
SEALED_SECRETS_SECRET_NAME ?= devops-cluster/sealed-secrets-master-key

# ----------------------------------------------------------------------------

.PHONY: help all setup-github docker-login terraform-infra terraform-status cluster dns argocd \
        sealed-secrets reseal-secrets backup-sealing-key restore-sealing-key \
        app observability backup velero-install status stop \
        restart destroy blue-green backup-run logs open clean clean-all \
        ensure-kustomize

# ----------------------------------------------------------------------------
# help — list all targets with descriptions
# ----------------------------------------------------------------------------
help:
	@echo -e "\n$(CYAN)$(BOLD)  OpenPanel DevOps — Available commands$(RESET)\n"
	@echo -e "$(BOLD)  Full install (from scratch):$(RESET)"
	@echo -e "    make all GITHUB_USER=<user> GITHUB_TOKEN=<token>"
	@echo -e "    $(YELLOW)or$(RESET) set credentials in .secrets and run: make all GITHUB_USER=<user>"
	@echo ""
	@echo -e "$(BOLD)  Step by step:$(RESET)"
	@echo -e "    $(CYAN)make setup-github$(RESET)          Create GitHub repo and configure CI/CD secrets"
	@echo -e "    $(CYAN)make docker-login$(RESET)          Log in to GHCR with the GitHub token"
	@echo -e "    $(CYAN)make terraform-infra$(RESET)       Provision S3 bucket + Secrets Manager slot (LocalStack auto-started)"
	@echo -e "    $(CYAN)make terraform-status$(RESET)      Verify all Terraform-managed resources exist"
	@echo -e "    $(CYAN)make cluster$(RESET)               Start Minikube, create namespaces, configure /etc/hosts"
	@echo -e "    $(CYAN)make dns$(RESET)                   Refresh /etc/hosts (useful if Minikube IP changes)"
	@echo -e "    $(CYAN)make argocd$(RESET)                Install ArgoCD into the cluster"
	@echo -e "    $(CYAN)make sealed-secrets$(RESET)        Install Sealed Secrets controller and seal all secrets"
	@echo -e "    $(CYAN)make reseal-secrets$(RESET)        Re-seal all secrets with the current cluster key"
	@echo -e "    $(CYAN)make backup-sealing-key$(RESET)    Export controller key to AWS Secrets Manager"
	@echo -e "    $(CYAN)make restore-sealing-key$(RESET)   Restore controller key from AWS Secrets Manager"
	@echo -e "    $(CYAN)make argocd$(RESET)                Install ArgoCD and bootstrap App of Apps (ENV=$(ENV))"
	@echo ""
	@echo -e "$(BOLD)  Manual deploy (ArgoCD alternative):$(RESET)"
	@echo -e "    $(CYAN)make app$(RESET)                   Deploy the application via kustomize"
	@echo -e "    $(CYAN)make observability$(RESET)         Deploy Prometheus, Grafana, Loki, Tempo"
	@echo -e "    $(CYAN)make backup$(RESET)                Deploy MinIO backup stack"
	@echo ""
	@echo -e "$(BOLD)  Operations:$(RESET)"
	@echo -e "    $(CYAN)make open$(RESET)                  Open all service UIs in the browser"
	@echo -e "    $(CYAN)make blue-green$(RESET)            Run the API Blue-Green switch"
	@echo -e "    $(CYAN)make backup-run$(RESET)            Create a manual Velero backup"
	@echo -e "    $(CYAN)make logs$(RESET)                  Tail logs from the app pods"
	@echo -e "    $(CYAN)make status$(RESET)                Show overall cluster status"
	@echo ""
	@echo -e "$(BOLD)  Cluster lifecycle:$(RESET)"
	@echo -e "    $(CYAN)make stop$(RESET)                  Stop Minikube"
	@echo -e "    $(CYAN)make restart$(RESET)               Stop and restart Minikube"
	@echo -e "    $(CYAN)make destroy$(RESET)               Delete the cluster completely"
	@echo ""
	@echo -e "$(BOLD)  Cleanup:$(RESET)"
	@echo -e "    $(CYAN)make clean$(RESET)                 Stop/delete Minikube and clean /etc/hosts"
	@echo -e "    $(CYAN)make clean-all$(RESET)             clean + remove credentials and Helm repos"
	@echo ""
	@echo -e "$(BOLD)  Key variables (override on command line or in .secrets):$(RESET)"
	@echo -e "    GITHUB_USER    GitHub username           (current: $(GITHUB_USER))"
	@echo -e "    REPO_NAME      Repository name           (current: $(REPO_NAME))"
	@echo -e "    GITHUB_TOKEN   GitHub OAuth token        (set in .secrets or CLI)"
	@echo -e "    PROFILE        Minikube profile          (current: $(PROFILE))"
	@echo -e "    APP_NAMESPACE  App namespace for logs/status (current: $(APP_NAMESPACE))"
	@echo -e "    ENV            Target environment        (current: $(ENV))"
	@echo -e "    SECRETS_FILE   Credentials file path     (current: $(SECRETS_FILE))"
	@echo ""

# ----------------------------------------------------------------------------
# all — full install in one command
# ----------------------------------------------------------------------------
all: setup-github docker-login terraform-infra cluster argocd sealed-secrets open
	$(call header,Install complete)
	$(call success,ArgoCD will now sync the cluster automatically)
	@echo ""
	$(call info,$(BOLD)Access points:$(RESET))
	$(call info,  App:        http://openpanel.local)
	$(call info,  ArgoCD:     http://argocd.local)
	$(call info,  Grafana:    http://grafana.local)
	$(call info,  Prometheus: http://prometheus.local)
	@echo ""

# ----------------------------------------------------------------------------
# setup-github — create the GitHub repo and configure CI/CD
# ----------------------------------------------------------------------------
setup-github:
	$(call header,Configuring GitHub repository)
	@if [ -z "$(GITHUB_USER)" ]; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: GITHUB_USER is required$(RESET)"; exit 1; fi
	@if [ -z "$(GITHUB_TOKEN)" ]; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: GITHUB_TOKEN is required (set in .secrets or CLI)$(RESET)"; exit 1; fi

	@# Initialise git if not already done
	@if [ ! -d ".git" ]; then \
		git init; \
		git add .gitignore; \
		git commit -m "Initial commit: project structure"; \
	fi

	$(call step,Replacing GITHUB_USER placeholder in manifests)
	@grep -rl "GITHUB_USER" k8s/ .github/ 2>/dev/null | \
		xargs sed -i "s/GITHUB_USER/$(GITHUB_USER)/g" || true

	$(call step,Creating repository on GitHub)
	@gh repo create $(GITHUB_USER)/$(REPO_NAME) --public --source=. --push 2>/dev/null || \
		echo -e "  $(YELLOW)Repo already exists — continuing$(RESET)"

	$(call step,Configuring GitHub Actions write permissions)
	@gh api -X PUT repos/$(GITHUB_USER)/$(REPO_NAME)/actions/permissions/workflow \
		-f default_workflow_permissions=write \
		-F can_approve_pull_request_reviews=false

	$(call step,Setting REGISTRY_OWNER variable)
	@gh variable set REGISTRY_OWNER \
		--repo $(GITHUB_USER)/$(REPO_NAME) \
		--body "$(shell echo $(GITHUB_USER) | tr '[:upper:]' '[:lower:]')"

	$(call step,Pushing project structure)
	@git add k8s/ .github/ scripts/ Makefile credentials-velero.example
	@git diff --staged --quiet || \
		git commit -m "feat: add k8s manifests, CI/CD workflows, scripts and Makefile"
	@git push -u origin master 2>/dev/null || git push -u origin main 2>/dev/null || true

	$(call success,GitHub repository configured)

# ----------------------------------------------------------------------------
# docker-login — authenticate to GHCR using the GitHub token
# ----------------------------------------------------------------------------
docker-login:
	$(call header,Logging in to GHCR)
	@if [ -z "$(GITHUB_TOKEN)" ]; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: GITHUB_TOKEN is required$(RESET)"; exit 1; fi
	@echo $(GITHUB_TOKEN) | docker login ghcr.io -u $(GITHUB_USER) --password-stdin
	$(call success,Logged in to ghcr.io as $(GITHUB_USER))

# ----------------------------------------------------------------------------
# terraform-infra — provision S3 bucket + Secrets Manager slot via Terraform
#
# Runs before the cluster exists. Provisions the external infrastructure that
# in-cluster components depend on:
#   - S3 bucket for Velero backups (BackupStorageLocation target)
#   - Secrets Manager slot for the Sealed Secrets RSA key backup
#   - IAM User + credentials written to credentials-velero (staging only)
#
# Prerequisites (staging):
#   - terraform >= 1.5.0
#   - docker >= 20.10 (LocalStack requirement)
#   - aws CLI v2: installed automatically if not found
#   - LocalStack: started automatically if not running (requires docker)
# ----------------------------------------------------------------------------
terraform-infra:
	$(call header,Provisioning infrastructure with Terraform \(ENV=$(ENV)\))
	$(call step,Checking prerequisites)
	@if ! command -v terraform &>/dev/null; then \
		echo -e "$(YELLOW)  terraform not found — installing v1.9.8 to ~/.local/bin...$(RESET)"; \
		mkdir -p $(HOME)/.local/bin; \
		TF_ZIP="terraform_1.9.8_linux_amd64.zip"; \
		curl -fsSL "https://releases.hashicorp.com/terraform/1.9.8/$$TF_ZIP" -o "/tmp/$$TF_ZIP"; \
		unzip -qo "/tmp/$$TF_ZIP" -d $(HOME)/.local/bin; \
		rm -f "/tmp/$$TF_ZIP"; \
		echo -e "$(GREEN)$(BOLD)✔ terraform installed to ~/.local/bin$(RESET)"; \
	fi
	@TF_VER=$$(terraform version 2>/dev/null | head -1 | sed 's/Terraform v//'); \
	TF_MAJOR=$$(echo "$$TF_VER" | cut -d. -f1); \
	TF_MINOR=$$(echo "$$TF_VER" | cut -d. -f2); \
	if [[ "$$TF_MAJOR" -lt 1 ]] || { [[ "$$TF_MAJOR" -eq 1 ]] && [[ "$$TF_MINOR" -lt 5 ]]; }; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: terraform >= 1.5.0 required (found v$$TF_VER)$(RESET)" >&2; \
		exit 1; \
	fi; \
	echo -e "$(GREEN)$(BOLD)✔ terraform v$$TF_VER$(RESET)"
	@if ! command -v aws &>/dev/null; then \
		echo -e "$(YELLOW)  aws CLI not found — installing v2 to ~/.local/bin...$(RESET)"; \
		curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"; \
		unzip -qo /tmp/awscliv2.zip -d /tmp; \
		/tmp/aws/install --install-dir $(HOME)/.local/aws-cli --bin-dir $(HOME)/.local/bin; \
		rm -rf /tmp/aws /tmp/awscliv2.zip; \
		echo -e "$(GREEN)$(BOLD)✔ aws CLI installed to ~/.local/bin$(RESET)"; \
	fi
	@AWS_VER=$$(aws --version 2>&1 | grep -o 'aws-cli/[0-9]*' | cut -d/ -f2); \
	if [ "$$AWS_VER" != "2" ]; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: aws CLI v2 required — v1 is EOL (found v$$AWS_VER)$(RESET)" >&2; \
		echo -e "  Install v2 from: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html" >&2; \
		exit 1; \
	fi; \
	echo -e "$(GREEN)$(BOLD)✔ aws CLI v$$AWS_VER$(RESET)"
	@if [ "$(ENV)" = "staging" ]; then \
		if ! command -v docker &>/dev/null; then \
			echo -e "$(RED)$(BOLD)✖ ERROR: docker is not installed or not in PATH$(RESET)" >&2; \
			echo -e "  Install from: https://docs.docker.com/engine/install/" >&2; \
			exit 1; \
		fi; \
		DOCKER_VER=$$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1,2); \
		DOCKER_MAJOR=$$(echo "$$DOCKER_VER" | cut -d. -f1); \
		DOCKER_MINOR=$$(echo "$$DOCKER_VER" | cut -d. -f2); \
		if [[ -z "$$DOCKER_MAJOR" ]] || [[ "$$DOCKER_MAJOR" -lt 20 ]] || \
		   { [[ "$$DOCKER_MAJOR" -eq 20 ]] && [[ "$$DOCKER_MINOR" -lt 10 ]]; }; then \
			echo -e "$(RED)$(BOLD)✖ ERROR: docker >= 20.10 required for LocalStack (found v$$DOCKER_VER)$(RESET)" >&2; \
			exit 1; \
		fi; \
		echo -e "$(GREEN)$(BOLD)✔ docker v$$DOCKER_VER$(RESET)"; \
		if ! curl -sf --max-time 3 http://localhost:4566/_localstack/health &>/dev/null; then \
			echo -e "$(YELLOW)  LocalStack not running — starting container...$(RESET)"; \
			if docker ps -a --format '{{.Names}}' | grep -q '^localstack$$'; then \
				docker rm -f localstack; \
			fi; \
			docker run -d -p 4566:4566 --name localstack \
				-e SERVICES=s3,iam,secretsmanager \
				localstack/localstack:3.4; \
			echo -e "  Waiting for LocalStack to be ready..."; \
			sleep 3; \
			for i in $$(seq 1 60); do \
				if curl -sf --max-time 2 http://localhost:4566/_localstack/health &>/dev/null; then \
					break; \
				fi; \
				if [[ "$$i" -eq 60 ]]; then \
					echo -e "$(RED)$(BOLD)✖ ERROR: LocalStack did not become healthy after 60s$(RESET)" >&2; \
					exit 1; \
				fi; \
				sleep 1; \
			done; \
		fi; \
		echo -e "$(GREEN)$(BOLD)✔ LocalStack is reachable at localhost:4566$(RESET)"; \
	fi
	@if [ ! -d "terraform/environments/$(ENV)" ]; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: environment '$(ENV)' not found in terraform/environments/$(RESET)" >&2; \
		echo -e "  Available: $$(ls terraform/environments/)" >&2; \
		exit 1; \
	fi
	@echo -e "$(GREEN)$(BOLD)✔ environment terraform/environments/$(ENV) exists$(RESET)"
	$(call step,Initialising Terraform in terraform/environments/$(ENV))
	@cd terraform/environments/$(ENV) && terraform init -input=false
	$(call step,Generating execution plan)
	@cd terraform/environments/$(ENV) && terraform plan -input=false -out=tfplan.bin
	@cd terraform/environments/$(ENV) && terraform show -no-color tfplan.bin > tfplan.txt
	@echo ""
	@echo -e "$(CYAN)$(BOLD)--- Plan saved to terraform/environments/$(ENV)/tfplan.txt ---$(RESET)"
	@echo ""
	@printf "$(CYAN)$(BOLD)Apply the above plan? [y/N]: $(RESET)" && read confirm && \
		[[ "$${confirm}" == "y" ]] || [[ "$${confirm}" == "Y" ]] || \
		{ echo -e "$(YELLOW)Aborted — no changes applied$(RESET)"; exit 1; }
	$(call step,Applying plan)
	@cd terraform/environments/$(ENV) && terraform apply tfplan.bin
	@cd terraform/environments/$(ENV) && rm -f tfplan.bin tfplan.txt
	$(call step,Writing credentials-velero)
	@if [ "$(ENV)" = "staging" ]; then \
		cd terraform/environments/$(ENV) && \
		printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
		"$$(terraform output -raw velero_access_key_id 2>/dev/null || echo 'N/A')" \
		"$$(terraform output -raw velero_secret_access_key 2>/dev/null || echo 'N/A')" \
		> $(CURDIR)/terraform/environments/staging/credentials-velero; \
		echo -e "$(GREEN)$(BOLD)✔ credentials-velero written to terraform/environments/staging/$(RESET)"; \
	else \
		echo -e "$(CYAN)  Prod uses IRSA — no credentials file needed$(RESET)"; \
	fi
	$(call success,Infrastructure ready)

# ----------------------------------------------------------------------------
# terraform-status — verify all resources created by terraform-infra
#
# Reads Terraform outputs and queries the AWS API (LocalStack for staging,
# real AWS for prod) to confirm every resource exists and is configured.
# ----------------------------------------------------------------------------
terraform-status:
	$(call header,Terraform resource status \(ENV=$(ENV)\))
	@if [ ! -d "terraform/environments/$(ENV)" ]; then \
		echo -e "$(RED)$(BOLD)✖ ERROR: environment '$(ENV)' not found$(RESET)" >&2; exit 1; \
	fi
	@if [ ! -f "terraform/environments/$(ENV)/terraform.tfstate" ] && [ "$(ENV)" = "staging" ]; then \
		echo -e "$(RED)$(BOLD)✖ No state file found — run: make terraform-infra ENV=$(ENV) first$(RESET)" >&2; exit 1; \
	fi
	$(call step,Terraform managed resources)
	@cd terraform/environments/$(ENV) && terraform state list
	@echo ""
	$(call step,Terraform outputs)
	@cd terraform/environments/$(ENV) && terraform output
	@echo ""
	$(call step,S3 buckets in $(ENV))
	@if [ "$(ENV)" = "staging" ]; then \
		aws --endpoint-url http://localhost:4566 s3 ls; \
	else \
		aws s3 ls; \
	fi
	@echo ""
	$(call step,S3 bucket versioning)
	@BUCKET=$$(cd terraform/environments/$(ENV) && terraform output -raw s3_bucket_name 2>/dev/null); \
	if [ "$(ENV)" = "staging" ]; then \
		aws --endpoint-url http://localhost:4566 s3api get-bucket-versioning --bucket "$$BUCKET"; \
	else \
		aws s3api get-bucket-versioning --bucket "$$BUCKET"; \
	fi
	@echo ""
	$(call step,Secrets Manager secrets in $(ENV))
	@if [ "$(ENV)" = "staging" ]; then \
		aws --endpoint-url http://localhost:4566 secretsmanager list-secrets \
			--query 'SecretList[].{Name:Name,ARN:ARN}' --output table; \
	else \
		aws secretsmanager list-secrets \
			--query 'SecretList[].{Name:Name,ARN:ARN}' --output table; \
	fi
	@echo ""
	@if [ "$(ENV)" = "staging" ]; then \
		$(call step,IAM user and access keys \(staging only\)); \
		aws --endpoint-url http://localhost:4566 iam list-users \
			--query 'Users[].{User:UserName,Created:CreateDate}' --output table; \
		echo ""; \
		aws --endpoint-url http://localhost:4566 iam list-access-keys \
			--user-name velero-backup-user \
			--query 'AccessKeyMetadata[].{KeyId:AccessKeyId,Status:Status}' --output table 2>/dev/null || true; \
		echo ""; \
		$(call step,credentials-velero); \
		if [ -f terraform/environments/staging/credentials-velero ]; then \
			cat terraform/environments/staging/credentials-velero; \
		else \
			echo -e "$(YELLOW)  credentials-velero not found — run: make terraform-infra ENV=staging$(RESET)"; \
		fi; \
	else \
		$(call step,IAM role \(prod IRSA\)); \
		cd terraform/environments/$(ENV) && terraform output velero_role_arn 2>/dev/null || true; \
	fi
	$(call success,Status check complete)

# ----------------------------------------------------------------------------
# cluster — start Minikube and configure namespaces + DNS
# ----------------------------------------------------------------------------
cluster:
	$(call header,Starting Minikube cluster)
	$(SCRIPTS_DIR)/setup-minikube.sh

dns:
	$(call header,Refreshing /etc/hosts DNS entries)
	@if grep -q "openpanel.local" /etc/hosts; then \
		echo -e "  $(YELLOW)Existing entries found — updating IP$(RESET)"; \
		sudo sed -i '/openpanel.local/d' /etc/hosts; \
	fi
	@echo "$(shell minikube ip -p $(PROFILE)) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
		| sudo tee -a /etc/hosts
	$(call success,DNS updated. Verify with: grep openpanel.local /etc/hosts)

stop:
	$(call header,Stopping Minikube)
	minikube stop -p $(PROFILE)

restart:
	$(call header,Restarting Minikube)
	minikube stop -p $(PROFILE) || true
	minikube start -p $(PROFILE)
	$(call success,Cluster restarted)

destroy:
	$(call header,Destroying Minikube cluster)
	minikube delete -p $(PROFILE)
	$(call success,Cluster deleted)

# ----------------------------------------------------------------------------
# clean — stop and delete Minikube, remove DNS entries from /etc/hosts
# ----------------------------------------------------------------------------
clean:
	$(call header,Cleaning up cluster and DNS)
	@minikube stop -p $(PROFILE) 2>/dev/null || true
	@minikube delete -p $(PROFILE) 2>/dev/null || true
	@sudo sed -i '/openpanel\.local/d' /etc/hosts 2>/dev/null || true
	$(call success,Cluster removed and DNS cleaned)

# clean-all — clean + remove generated credentials and Helm repos
clean-all: clean
	$(call step,Removing Velero credentials file)
	@rm -f terraform/environments/staging/credentials-velero
	$(call step,Removing Helm repos added by this project)
	@helm repo remove argo 2>/dev/null || true
	$(call success,Full cleanup complete)

# ----------------------------------------------------------------------------
# ensure-kustomize — auto-install kustomize v5.4.3 if not in PATH
#
# Used as a prerequisite by: argocd, sealed-secrets, observability.
# Installs to ~/.local/bin (already in PATH via the export above).
# ----------------------------------------------------------------------------
KUSTOMIZE_VERSION := 5.4.3

ensure-kustomize:
	@if ! command -v kustomize &>/dev/null; then \
		echo -e "$(YELLOW)  kustomize not found — installing v$(KUSTOMIZE_VERSION) to ~/.local/bin...$(RESET)"; \
		mkdir -p $(HOME)/.local/bin; \
		KZ_TGZ="kustomize_v$(KUSTOMIZE_VERSION)_linux_amd64.tar.gz"; \
		curl -fsSL \
		  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv$(KUSTOMIZE_VERSION)/$$KZ_TGZ" \
		  -o "/tmp/$$KZ_TGZ"; \
		tar -xzf "/tmp/$$KZ_TGZ" -C $(HOME)/.local/bin; \
		rm -f "/tmp/$$KZ_TGZ"; \
		echo -e "$(GREEN)$(BOLD)✔ kustomize v$(KUSTOMIZE_VERSION) installed to ~/.local/bin$(RESET)"; \
	fi
	@KZ_VER=$$(kustomize version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1); \
	echo -e "$(GREEN)$(BOLD)✔ kustomize $$KZ_VER$(RESET)"

# ----------------------------------------------------------------------------
# argocd — install ArgoCD and bootstrap the App of Apps
#
# Renders overlays/<ENV>/argocd via kustomize+Helm, applies the result,
# then applies bootstrap-app.yaml so ArgoCD manages itself and all
# Application CRs going forward. No separate argocd-apps step needed.
# ----------------------------------------------------------------------------
argocd: ensure-kustomize
	$(call header,Installing ArgoCD \(ENV=$(ENV)\))
	$(SCRIPTS_DIR)/install-argocd.sh $(ENV)

# ----------------------------------------------------------------------------
# sealed-secrets — install controller and seal all secrets
# ----------------------------------------------------------------------------
sealed-secrets: ensure-kustomize
	$(call header,Installing Sealed Secrets controller \(ENV=$(ENV)\))
	@# Namespace must exist — declared in base/namespaces/namespaces.yaml and
	@# applied by `make cluster`. Fail early with a clear message if missing.
	@kubectl get namespace sealed-secrets > /dev/null 2>&1 || \
		(echo -e "$(RED)$(BOLD)✖ ERROR: namespace 'sealed-secrets' not found. Run 'make cluster' first.$(RESET)" && exit 1)
	@# Step 1: install controller only (base — no secrets.yaml).
	@# The SealedSecret CRD is registered by the Helm chart. We must wait for it
	@# before applying secrets.yaml, otherwise kubectl rejects the unknown CRD kind.
	$(call step,Installing controller \(base — no SealedSecret resources yet\))
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
		k8s/infrastructure/base/sealed-secrets \
		| kubectl apply -f -
	$(call step,Waiting for SealedSecret CRD to be established)
	kubectl wait --for=condition=Established \
		crd/sealedsecrets.bitnami.com --timeout=60s
	$(call step,Waiting for controller pod to become ready)
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets \
		-n sealed-secrets --timeout=120s
	@if [ ! -f $(SEALED_SECRETS_FILE) ]; then \
		echo -e "$(CYAN)  → No secrets.yaml found — running initial seal...$(RESET)"; \
		$(MAKE) reseal-secrets ENV=$(ENV); \
	else \
		echo -e "$(CYAN)  → secrets.yaml already exists — skipping reseal (run 'make reseal-secrets' to rotate)$(RESET)"; \
	fi
	@# Step 2: apply the full overlay now that the CRD exists.
	$(call step,Applying sealed secrets)
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
		k8s/infrastructure/overlays/$(ENV)/sealed-secrets \
		| kubectl apply -f -
	$(call success,Sealed Secrets installed and secrets applied)
	@echo ""
	$(call info,$(YELLOW)$(BOLD)Back up the controller key before destroying the cluster:$(RESET))
	$(call info,  make backup-sealing-key)
	@echo ""

# reseal-secrets — re-encrypt all secrets with the current cluster key
# Run this whenever the cluster is recreated (each cluster has a unique key).
#
# Usage:
#   make reseal-secrets                              # staging, dev defaults
#   make reseal-secrets ENV=prod \
#     POSTGRES_PASSWORD=xxx REDIS_PASSWORD=xxx ...  # prod, real passwords
reseal-secrets:
	$(call header,Re-sealing secrets \(ENV=$(ENV)\))
	$(call step,Fetching controller certificate)
	@kubeseal --fetch-cert \
		--controller-namespace sealed-secrets \
		--controller-name sealed-secrets \
		> /tmp/sealed-secrets-cert.pem

	@# Write file header
	@printf '# =============================================================================\n' > $(SEALED_SECRETS_FILE)
	@printf '# Sealed Secrets — All cluster credentials\n' >> $(SEALED_SECRETS_FILE)
	@printf '#\n' >> $(SEALED_SECRETS_FILE)
	@printf '# Sections:\n' >> $(SEALED_SECRETS_FILE)
	@printf '#   1. postgres-credentials        (namespace: openpanel)\n' >> $(SEALED_SECRETS_FILE)
	@printf '#   2. redis-credentials           (namespace: openpanel)\n' >> $(SEALED_SECRETS_FILE)
	@printf '#   3. clickhouse-credentials      (namespace: openpanel)\n' >> $(SEALED_SECRETS_FILE)
	@printf '#   4. openpanel-secrets           (namespace: openpanel)\n' >> $(SEALED_SECRETS_FILE)
	@printf '#   5. grafana-admin-credentials   (namespace: observability)\n' >> $(SEALED_SECRETS_FILE)
	@printf '#   6. minio-credentials           (namespace: backup)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# =============================================================================\n' >> $(SEALED_SECRETS_FILE)

	$(call step,Sealing postgres-credentials)
	@printf '\n# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@printf '# 1. PostgreSQL credentials\n' >> $(SEALED_SECRETS_FILE)
	@printf '#    Used by: postgres StatefulSet, openpanel-secrets (DATABASE_URL)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@kubectl create secret generic postgres-credentials \
		--from-literal=POSTGRES_USER=$(POSTGRES_USER) \
		--from-literal=POSTGRES_PASSWORD=$(POSTGRES_PASSWORD) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		>> $(SEALED_SECRETS_FILE)

	$(call step,Sealing redis-credentials)
	@printf '\n# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@printf '# 2. Redis credentials\n' >> $(SEALED_SECRETS_FILE)
	@printf '#    Used by: redis Deployment, openpanel-secrets (REDIS_URL)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@kubectl create secret generic redis-credentials \
		--from-literal=REDIS_PASSWORD=$(REDIS_PASSWORD) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		>> $(SEALED_SECRETS_FILE)

	$(call step,Sealing clickhouse-credentials)
	@printf '\n# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@printf '# 3. ClickHouse credentials\n' >> $(SEALED_SECRETS_FILE)
	@printf '#    Used by: clickhouse StatefulSet, openpanel-secrets (CLICKHOUSE_URL)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@kubectl create secret generic clickhouse-credentials \
		--from-literal=CLICKHOUSE_USER=$(CLICKHOUSE_USER) \
		--from-literal=CLICKHOUSE_PASSWORD=$(CLICKHOUSE_PASSWORD) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		>> $(SEALED_SECRETS_FILE)

	$(call step,Sealing openpanel-secrets)
	@printf '\n# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@printf '# 4. OpenPanel application secrets\n' >> $(SEALED_SECRETS_FILE)
	@printf '#    Used by: api and worker Deployments (envFrom)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@kubectl create secret generic openpanel-secrets \
		--from-literal=DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres.openpanel.svc.cluster.local:5432/openpanel \
		--from-literal=DATABASE_URL_DIRECT=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres.openpanel.svc.cluster.local:5432/openpanel \
		--from-literal=CLICKHOUSE_URL=http://$(CLICKHOUSE_USER):$(CLICKHOUSE_PASSWORD)@clickhouse.openpanel.svc.cluster.local:8123 \
		--from-literal=REDIS_URL=redis://:$(REDIS_PASSWORD)@redis.openpanel.svc.cluster.local:6379 \
		--from-literal=API_SECRET=$(API_SECRET) \
		--namespace openpanel --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		>> $(SEALED_SECRETS_FILE)

	$(call step,Sealing grafana-admin-credentials)
	@printf '\n# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@printf '# 5. Grafana admin credentials\n' >> $(SEALED_SECRETS_FILE)
	@printf '#    Used by: kube-prometheus-stack (grafana.admin.existingSecret)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@kubectl create secret generic grafana-admin-credentials \
		--from-literal=admin-user=$(GRAFANA_USER) \
		--from-literal=admin-password=$(GRAFANA_PASSWORD) \
		--namespace observability --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		>> $(SEALED_SECRETS_FILE)

	$(call step,Sealing minio-credentials)
	@printf '\n# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@printf '# 6. MinIO credentials\n' >> $(SEALED_SECRETS_FILE)
	@printf '#    Used by: minio Deployment (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD)\n' >> $(SEALED_SECRETS_FILE)
	@printf '# -----------------------------------------------------------------------------\n' >> $(SEALED_SECRETS_FILE)
	@kubectl create secret generic minio-credentials \
		--from-literal=MINIO_ROOT_USER=$(MINIO_USER) \
		--from-literal=MINIO_ROOT_PASSWORD=$(MINIO_PASSWORD) \
		--namespace backup --dry-run=client -o yaml | \
	kubeseal --cert /tmp/sealed-secrets-cert.pem --format yaml \
		>> $(SEALED_SECRETS_FILE)

	@rm -f /tmp/sealed-secrets-cert.pem
	$(call success,All secrets re-sealed → $(SEALED_SECRETS_FILE))

# backup-sealing-key — export the controller RSA key to AWS Secrets Manager
# Run once immediately after `make sealed-secrets` on every new cluster.
# Without this backup, losing the cluster means all secrets must be re-sealed.
backup-sealing-key:
	$(call header,Backing up Sealed Secrets key to AWS Secrets Manager)
	@kubectl get secret -n sealed-secrets \
		-l sealedsecrets.bitnami.com/sealed-secrets-key \
		-o yaml > /tmp/sealed-secrets-master-key.yaml
	@aws secretsmanager put-secret-value \
		--endpoint-url $(LOCALSTACK_ENDPOINT) \
		--secret-id $(SEALED_SECRETS_SECRET_NAME) \
		--secret-string "$$(cat /tmp/sealed-secrets-master-key.yaml)" \
		--region us-east-1
	@rm -f /tmp/sealed-secrets-master-key.yaml
	$(call success,Key backed up to: $(SEALED_SECRETS_SECRET_NAME))

# restore-sealing-key — import the controller key on a new cluster
# Run BEFORE applying sealed secrets. After restore the controller can decrypt
# all previously sealed blobs — no need to re-seal anything.
restore-sealing-key:
	$(call header,Restoring Sealed Secrets key from AWS Secrets Manager)
	@aws secretsmanager get-secret-value \
		--endpoint-url $(LOCALSTACK_ENDPOINT) \
		--secret-id $(SEALED_SECRETS_SECRET_NAME) \
		--query SecretString \
		--output text \
		--region us-east-1 > /tmp/sealed-secrets-master-key.yaml
	@kubectl apply -f /tmp/sealed-secrets-master-key.yaml
	@kubectl rollout restart deployment sealed-secrets -n sealed-secrets
	@kubectl rollout status deployment sealed-secrets -n sealed-secrets --timeout=60s
	@rm -f /tmp/sealed-secrets-master-key.yaml
	$(call success,Key restored — existing sealed secrets are now decryptable)

# ----------------------------------------------------------------------------
# Manual deploy targets (alternative to ArgoCD)
# ----------------------------------------------------------------------------
app:
	$(call header,Deploying application via kustomize \(ENV=$(ENV)\))
	kubectl apply -k k8s/apps/overlays/$(ENV)
	$(call success,Application deployed)

# Observability uses helmChartInflationGenerator — requires --enable-helm flag.
# This is the direct kustomize path; ArgoCD uses the same path with buildOptions.
observability: ensure-kustomize
	$(call header,Deploying observability stack \(ENV=$(ENV)\))
	kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
		k8s/infrastructure/overlays/$(ENV)/observability \
		| kubectl apply -f -
	$(call success,Observability stack deployed)

velero-install:
	$(call header,Installing Velero operator via Helm \(ENV=$(ENV)\))
	@helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
	@helm repo update vmware-tanzu
	$(call step,Installing Velero chart \(credentials from credentials-velero\))
	@if [ "$(ENV)" = "staging" ]; then \
		CRED_FILE="terraform/environments/staging/credentials-velero"; \
		if [ ! -f "$$CRED_FILE" ]; then \
			echo "$(RED)ERROR: $$CRED_FILE not found — run: make terraform-infra ENV=staging$(RESET)"; \
			exit 1; \
		fi; \
		kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -; \
		kubectl create secret generic velero-credentials \
			--namespace velero \
			--from-file=cloud="$$CRED_FILE" \
			--dry-run=client -o yaml | kubectl apply -f -; \
		helm upgrade --install velero vmware-tanzu/velero \
			--namespace velero \
			--version "8.0.0" \
			--set "configuration.backupStorageLocation[0].provider=aws" \
			--set "configuration.backupStorageLocation[0].bucket=openpanel-velero-staging" \
			--set "configuration.backupStorageLocation[0].config.region=us-east-1" \
			--set "configuration.backupStorageLocation[0].config.s3ForcePathStyle=true" \
			--set "configuration.backupStorageLocation[0].config.s3Url=http://localstack.backup.svc.cluster.local:4566" \
			--set "credentials.existingSecret=velero-credentials" \
			--set "deployNodeAgent=true" \
			--set "snapshotsEnabled=false" \
			--set "initContainers[0].name=velero-plugin-for-aws" \
			--set "initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0" \
			--set "initContainers[0].volumeMounts[0].mountPath=/target" \
			--set "initContainers[0].volumeMounts[0].name=plugins" \
			--wait --timeout 5m; \
	elif [ "$(ENV)" = "prod" ]; then \
		echo "$(YELLOW)Prod Velero uses IRSA — apply via Terraform/Helm with correct IAM role ARN$(RESET)"; \
	fi
	$(call step,Waiting for Velero CRDs to become established)
	@kubectl wait --for=condition=Established crd/backupstoragelocations.velero.io --timeout=120s
	$(call success,Velero operator installed — run: make backup ENV=$(ENV))

backup:
	$(call header,Deploying backup stack \(ENV=$(ENV)\))
	$(call step,Deploying MinIO)
	kubectl apply -k k8s/infrastructure/overlays/$(ENV)/minio
	$(call step,Deploying Velero schedules)
	kubectl apply -k k8s/infrastructure/overlays/$(ENV)/velero
	$(call success,Backup stack deployed)

# ----------------------------------------------------------------------------
# Operations
# ----------------------------------------------------------------------------
blue-green:
	$(call header,Running Blue-Green switch)
	$(SCRIPTS_DIR)/blue-green-switch.sh

backup-run:
	$(call header,Creating manual Velero backup)
	$(SCRIPTS_DIR)/backup-restore.sh backup $(APP_NAMESPACE)

logs:
	$(call header,Tailing logs — namespace: $(APP_NAMESPACE))
	kubectl logs -n $(APP_NAMESPACE) -l app=openpanel-api --tail=100 -f

# ----------------------------------------------------------------------------
# status — show overall cluster health at a glance
# ----------------------------------------------------------------------------
status:
	$(call header,Cluster status)
	@minikube status -p $(PROFILE) || true
	$(call header,Namespaces)
	@kubectl get namespaces
	$(call header,Pods [$(APP_NAMESPACE)])
	@kubectl get pods -n $(APP_NAMESPACE)
	$(call header,Pods [observability])
	@kubectl get pods -n observability
	$(call header,Pods [backup])
	@kubectl get pods -n backup
	$(call header,ArgoCD Applications)
	@kubectl get applications -n argocd 2>/dev/null || \
		echo -e "  $(YELLOW)ArgoCD not installed$(RESET)"
	@echo ""

# ----------------------------------------------------------------------------
# open — launch all service UIs in the browser
# ----------------------------------------------------------------------------
open:
	$(call header,Opening services in browser)
	@xdg-open http://openpanel.local &
	@xdg-open http://api.openpanel.local &
	@xdg-open http://argocd.local &
	@xdg-open http://grafana.local &
	@xdg-open http://prometheus.local &
	$(call success,Services opened)
