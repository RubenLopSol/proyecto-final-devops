#!/bin/bash
set -euo pipefail

# =============================================================================
# Blue-Green Deployment Switch for OpenPanel API
# =============================================================================

NAMESPACE="openpanel"
SERVICE="openpanel-api"

# Get current active version
CURRENT=$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.selector.version}')

if [ "${CURRENT}" = "blue" ]; then
  TARGET="green"
else
  TARGET="blue"
fi

echo "=== Blue-Green Switch ==="
echo "Current active: ${CURRENT}"
echo "Target:         ${TARGET}"
echo ""

# Step 1: Verify target deployment exists and has the right image
TARGET_DEPLOYMENT="${SERVICE}-${TARGET}"
echo "=== Step 1: Checking target deployment ${TARGET_DEPLOYMENT} ==="
kubectl get deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" || { echo "ERROR: Target deployment not found"; exit 1; }

# Step 2: Scale up target
echo "=== Step 2: Scaling up ${TARGET_DEPLOYMENT} to 2 replicas ==="
kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=2

# Step 3: Wait for target to be ready
echo "=== Step 3: Waiting for ${TARGET_DEPLOYMENT} to be ready ==="
kubectl rollout status deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --timeout=300s

# Step 4: Health check on target pods
echo "=== Step 4: Running health checks ==="
TARGET_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE},version=${TARGET}" -o jsonpath='{.items[*].metadata.name}')
ALL_HEALTHY=true
for POD in ${TARGET_PODS}; do
  STATUS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
  READY=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  echo "  Pod ${POD}: phase=${STATUS}, ready=${READY}"
  if [ "${STATUS}" != "Running" ] || [ "${READY}" != "True" ]; then
    ALL_HEALTHY=false
  fi
done

if [ "${ALL_HEALTHY}" != "true" ]; then
  echo "ERROR: Not all target pods are healthy. Aborting switch."
  echo "Rolling back: scaling ${TARGET_DEPLOYMENT} to 0"
  kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0
  exit 1
fi

# Step 5: Confirmation
echo ""
read -p "All health checks passed. Switch traffic to ${TARGET}? (y/N): " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
  echo "Aborted. Rolling back..."
  kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0
  exit 0
fi

# Step 6: Switch service selector
echo "=== Step 6: Switching service selector to ${TARGET} ==="
kubectl patch svc "${SERVICE}" -n "${NAMESPACE}" -p "{\"spec\":{\"selector\":{\"version\":\"${TARGET}\"}}}"

# Step 7: Verify traffic
echo "=== Step 7: Verifying service endpoints ==="
kubectl get endpoints "${SERVICE}" -n "${NAMESPACE}"
echo ""

# Step 8: Scale down old deployment
echo "=== Step 8: Scaling down ${SERVICE}-${CURRENT} ==="
read -p "Scale down old deployment (${CURRENT})? (y/N): " SCALEDOWN
if [ "${SCALEDOWN}" = "y" ] || [ "${SCALEDOWN}" = "Y" ]; then
  kubectl scale deployment "${SERVICE}-${CURRENT}" -n "${NAMESPACE}" --replicas=0
  echo "Old deployment scaled down."
else
  echo "Old deployment kept running for quick rollback."
fi

echo ""
echo "=== Switch complete ==="
echo "Active version: ${TARGET}"
echo ""
echo "To rollback instantly:"
echo "  kubectl patch svc ${SERVICE} -n ${NAMESPACE} -p '{\"spec\":{\"selector\":{\"version\":\"${CURRENT}\"}}}'"
