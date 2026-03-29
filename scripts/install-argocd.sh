#!/bin/bash
set -euo pipefail

# =============================================================================
# Install ArgoCD via Helm and bootstrap the App of Apps
#
# Usage:
#   ./scripts/install-argocd.sh
#
# What it does:
#   1. Validates prerequisites (helm, kubectl)
#   2. Installs or upgrades ArgoCD via Helm (idempotent)
#   3. Waits for the admin secret to be available
#   4. Applies the ArgoCD AppProject (defines permissions scope)
#   5. Applies the bootstrap Application (App of Apps — manages all other apps)
# =============================================================================

NAMESPACE="argocd"
ARGOCD_CHART_VERSION="7.7.0"
VALUES_FILE="k8s/helm/values/argocd.yaml"
HELM_MIN_MAJOR=3
HELM_MIN_MINOR=8

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header()  { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; }
step()    { echo -e "${YELLOW}--- $* ---${RESET}"; }
success() { echo -e "${GREEN}${BOLD}✔ $*${RESET}"; }
error()   { echo -e "${RED}${BOLD}✖ ERROR: $*${RESET}" >&2; }
info()    { echo -e "  $*"; }

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
check_prerequisites() {
  local missing=0

  header "Checking prerequisites"
  for cmd in helm kubectl; do
    if ! command -v "${cmd}" &>/dev/null; then
      error "'${cmd}' is not installed or not in PATH"
      missing=1
    else
      success "${cmd} found"
    fi
  done

  if [ "${missing}" -eq 1 ]; then
    echo ""
    error "Install missing tools and re-run this script."
    exit 1
  fi

  # Helm minimum version check (requires >= HELM_MIN_MAJOR.HELM_MIN_MINOR)
  step "Checking Helm version (minimum v${HELM_MIN_MAJOR}.${HELM_MIN_MINOR})"
  HELM_RAW=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  HELM_MAJOR=$(echo "${HELM_RAW}" | cut -d. -f1 | tr -d 'v')
  HELM_MINOR=$(echo "${HELM_RAW}" | cut -d. -f2)

  if [ -z "${HELM_MAJOR}" ]; then
    error "Could not determine Helm version. Output: $(helm version --short 2>&1 || true)"
    exit 1
  fi

  if [ "${HELM_MAJOR}" -lt "${HELM_MIN_MAJOR}" ] || \
     { [ "${HELM_MAJOR}" -eq "${HELM_MIN_MAJOR}" ] && [ "${HELM_MINOR}" -lt "${HELM_MIN_MINOR}" ]; }; then
    error "Helm v${HELM_MIN_MAJOR}.${HELM_MIN_MINOR}+ is required. Found: ${HELM_RAW}"
    info "Upgrade Helm: https://helm.sh/docs/intro/install/"
    exit 1
  fi

  success "Helm ${HELM_RAW} — OK"

  if [ ! -f "${VALUES_FILE}" ]; then
    error "Values file not found: ${VALUES_FILE}"
    info "Run this script from the repository root."
    exit 1
  fi

  success "Values file found: ${VALUES_FILE}"
}

# Wait for a Kubernetes secret to exist
wait_for_secret() {
  local namespace="${1}"
  local secret="${2}"
  local max_attempts=30
  local attempt=0

  step "Waiting for secret '${secret}' in namespace '${namespace}'..."
  until kubectl -n "${namespace}" get secret "${secret}" &>/dev/null; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      error "Secret '${secret}' not found after ${max_attempts} attempts."
      exit 1
    fi
    info "Attempt ${attempt}/${max_attempts} — retrying in 5s..."
    sleep 5
  done
  success "Secret '${secret}' is available"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
check_prerequisites

header "Adding ArgoCD Helm repository"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
success "Helm repository up to date"

# upgrade --install is idempotent: installs if not present, upgrades if already installed
header "Installing / upgrading ArgoCD (chart version ${ARGOCD_CHART_VERSION})"
step "namespace=${NAMESPACE} · values=${VALUES_FILE}"
helm upgrade --install argocd argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 5m
success "ArgoCD installed/upgraded"

header "Retrieving initial admin password"
wait_for_secret "${NAMESPACE}" "argocd-initial-admin-secret"
ARGOCD_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo ""
info "  ${BOLD}Username:${RESET} admin"
info "  ${BOLD}Password:${RESET} ${ARGOCD_PASSWORD}"

header "Applying ArgoCD AppProject (defines permission scope)"
kubectl apply -f k8s/argocd/projects/
success "AppProject applied"

header "Bootstrapping App of Apps"
kubectl apply -f k8s/argocd/bootstrap-app.yaml
success "Bootstrap Application applied"

echo ""
echo -e "${GREEN}${BOLD}=== ArgoCD installed and bootstrapped ===${RESET}"
echo ""
info "  Access:   ${BOLD}http://argocd.local${RESET}"
info "  Username: ${BOLD}admin${RESET}"
info "  Password: ${BOLD}${ARGOCD_PASSWORD}${RESET}"
echo ""
