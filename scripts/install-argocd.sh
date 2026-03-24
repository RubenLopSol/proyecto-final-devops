#!/bin/bash
set -euo pipefail

# =============================================================================
# Install and configure ArgoCD via Helm
# =============================================================================

NAMESPACE="argocd"
ARGOCD_CHART_VERSION="7.7.0"

echo "=== Installing ArgoCD via Helm ==="

# Add Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
helm install argocd argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${ARGOCD_CHART_VERSION}" \
  --set server.insecure=true \
  --set server.ingress.enabled=true \
  --set server.ingress.ingressClassName=nginx \
  --set "server.ingress.hosts[0]=argocd.local" \
  --wait \
  --timeout 5m

# Get initial admin password
echo "=== ArgoCD initial admin password ==="
ARGOCD_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Username: admin"
echo "Password: ${ARGOCD_PASSWORD}"

echo ""
echo "=== ArgoCD installed ==="
echo ""
echo "Access: http://argocd.local"
echo ""
echo "Next steps:"
echo "  1. Login: argocd login argocd.local --username admin --password ${ARGOCD_PASSWORD} --insecure"
echo "  2. Change password: argocd account update-password"
echo "  3. Apply ArgoCD applications: kubectl apply -f k8s/argocd/projects/ && kubectl apply -f k8s/argocd/applications/"
