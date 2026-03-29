#!/bin/bash
set -euo pipefail

# =============================================================================
# Setup Minikube cluster for OpenPanel DevOps project
#
# Usage:
#   ./scripts/setup-minikube.sh
#
# What it does:
#   1. Validates prerequisites (minikube, kubectl)
#   2. Starts a Minikube cluster (skips if already running)
#   3. Enables required addons
#   4. Creates the base Kubernetes namespaces
# =============================================================================

CLUSTER_NAME="openpanel"
K8S_VERSION="v1.28.0"
CPUS=6
MEMORY="8192"
DISK="60g"
DRIVER="docker"
MINIKUBE_MIN_MAJOR=1
MINIKUBE_MIN_MINOR=31   # v1.31+ is required to run Kubernetes v1.28

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
  for cmd in minikube kubectl docker; do
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

  # Minikube minimum version check (requires >= MINIKUBE_MIN_MAJOR.MINIKUBE_MIN_MINOR)
  step "Checking Minikube version (minimum v${MINIKUBE_MIN_MAJOR}.${MINIKUBE_MIN_MINOR})"
  MINIKUBE_RAW=$(minikube version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  MINIKUBE_MAJOR=$(echo "${MINIKUBE_RAW}" | cut -d. -f1 | tr -d 'v')
  MINIKUBE_MINOR=$(echo "${MINIKUBE_RAW}" | cut -d. -f2)

  if [ -z "${MINIKUBE_MAJOR}" ]; then
    error "Could not determine Minikube version. Output: $(minikube version --short 2>&1 || true)"
    exit 1
  fi

  if [ "${MINIKUBE_MAJOR}" -lt "${MINIKUBE_MIN_MAJOR}" ] || \
     { [ "${MINIKUBE_MAJOR}" -eq "${MINIKUBE_MIN_MAJOR}" ] && [ "${MINIKUBE_MINOR}" -lt "${MINIKUBE_MIN_MINOR}" ]; }; then
    error "Minikube v${MINIKUBE_MIN_MAJOR}.${MINIKUBE_MIN_MINOR}+ is required. Found: ${MINIKUBE_RAW}"
    info "Upgrade Minikube: https://minikube.sigs.k8s.io/docs/start/"
    exit 1
  fi

  success "Minikube ${MINIKUBE_RAW} — OK"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
check_prerequisites

header "Checking cluster status"
if minikube status --profile="${CLUSTER_NAME}" &>/dev/null; then
  info "Cluster '${BOLD}${CLUSTER_NAME}${RESET}' is already running. Skipping creation."
else
  header "Starting Minikube cluster: ${CLUSTER_NAME}"
  step "Kubernetes ${K8S_VERSION} · driver=${DRIVER} · CPUs=${CPUS} · memory=${MEMORY}MB · disk=${DISK}"
  minikube start \
    --profile="${CLUSTER_NAME}" \
    --kubernetes-version="${K8S_VERSION}" \
    --driver="${DRIVER}" \
    --cpus="${CPUS}" \
    --memory="${MEMORY}" \
    --disk-size="${DISK}" \
    --addons=ingress \
    --addons=metrics-server \
    --addons=storage-provisioner
  success "Cluster started"
fi

header "Verifying cluster"
kubectl cluster-info --context="minikube-${CLUSTER_NAME}" 2>/dev/null || kubectl cluster-info
kubectl get nodes

header "Creating namespaces"
kubectl apply -f k8s/base/namespaces/namespaces.yaml
kubectl get namespaces

MINIKUBE_IP=$(minikube ip --profile="${CLUSTER_NAME}")
DNS_HOSTS="openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local"

header "Configuring /etc/hosts"
step "Cluster IP: ${MINIKUBE_IP}"
if grep -q "openpanel.local" /etc/hosts; then
  info "Existing entry found — updating IP..."
  sudo sed -i '/openpanel\.local/d' /etc/hosts
fi
echo "${MINIKUBE_IP}  ${DNS_HOSTS}" | sudo tee -a /etc/hosts > /dev/null
success "/etc/hosts updated: ${BOLD}${MINIKUBE_IP}  ${DNS_HOSTS}${RESET}"

echo ""
echo -e "${GREEN}${BOLD}=== Setup complete ===${RESET}"
echo ""
success "Cluster IP: ${BOLD}${MINIKUBE_IP}${RESET}"
success "/etc/hosts configured for all services"
echo ""
