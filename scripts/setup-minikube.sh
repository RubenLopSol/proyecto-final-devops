#!/bin/bash
set -euo pipefail

# =============================================================================
# Setup Minikube cluster for OpenPanel DevOps project
# =============================================================================

CLUSTER_NAME="openpanel"
K8S_VERSION="v1.28.0"
CPUS=6
MEMORY="8192"
DISK="60g"
DRIVER="docker"

echo "=== Starting Minikube cluster: ${CLUSTER_NAME} ==="

# Start Minikube
minikube start \
  --profile="${CLUSTER_NAME}" \
  --kubernetes-version="${K8S_VERSION}" \
  --driver="${DRIVER}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --disk-size="${DISK}" \
  --addons=ingress,metrics-server,dashboard,storage-provisioner

echo "=== Minikube cluster started ==="

# Verify cluster
echo "=== Verifying cluster ==="
kubectl cluster-info
kubectl get nodes

# Create namespaces
echo "=== Creating namespaces ==="
kubectl apply -f k8s/base/namespaces/namespaces.yaml

# Verify namespaces
kubectl get namespaces

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Add DNS entries to /etc/hosts:"
echo "     echo \"\$(minikube ip -p ${CLUSTER_NAME}) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local\" | sudo tee -a /etc/hosts"
echo "  2. Install ArgoCD:  ./scripts/install-argocd.sh"
echo "  3. Install Sealed Secrets controller"
echo "  4. Create sealed secrets and commit them"
