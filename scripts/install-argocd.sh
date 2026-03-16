#!/bin/bash
set -euo pipefail

# =============================================================================
# Install and configure ArgoCD
# =============================================================================

ARGOCD_VERSION="stable"
NAMESPACE="argocd"

echo "=== Installing ArgoCD ==="

# Install ArgoCD
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${NAMESPACE}" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Wait for ArgoCD to be ready
echo "=== Waiting for ArgoCD pods to be ready ==="
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n "${NAMESPACE}" --timeout=300s

# Get initial admin password
echo "=== ArgoCD initial admin password ==="
ARGOCD_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Username: admin"
echo "Password: ${ARGOCD_PASSWORD}"

# Create Ingress for ArgoCD
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF

echo ""
echo "=== ArgoCD installed ==="
echo ""
echo "Access: https://argocd.local"
echo ""
echo "Next steps:"
echo "  1. Login: argocd login argocd.local --username admin --password ${ARGOCD_PASSWORD} --insecure"
echo "  2. Change password: argocd account update-password"
echo "  3. Apply ArgoCD applications: kubectl apply -f k8s/argocd/projects/ && kubectl apply -f k8s/argocd/applications/"
