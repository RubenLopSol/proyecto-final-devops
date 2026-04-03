# Runbook — Operational Procedures

**Final Project — Master in DevOps & Cloud Computing**

This runbook collects step-by-step procedures for the most common production situations: deployments, incidents, alerts, and maintenance.

---

## Index

1. [Deploying a new version](#1-deploying-a-new-version)
2. [Emergency rollback](#2-emergency-rollback)
3. [Pod in CrashLoopBackOff](#3-pod-in-crashloopbackoff)
4. [Prometheus won't start (TSDB lock)](#4-prometheus-wont-start-tsdb-lock)
5. [Alert: service down](#5-alert-service-down)
6. [Alert: high HTTP error rate](#6-alert-high-http-error-rate)
7. [Alert: high memory usage](#7-alert-high-memory-usage)
8. [Restore from backup](#8-restore-from-backup)
9. [Secret rotation](#9-secret-rotation)
10. [Starting the cluster from scratch](#10-starting-the-cluster-from-scratch)

---

## 1. Deploying a New Version

**Normal flow (automatic):**

```
Developer pushes to main
    ↓
CI runs lint + build + push image
    ↓
CD updates image tag in k8s/apps/base/openpanel/
    ↓
ArgoCD detects the change and deploys
    ↓
New version active (rolling update)
```

**Verify the deployment was successful:**

```bash
# 1. Check that the CI/CD pipeline is green
gh run list --limit 5

# 2. Check that ArgoCD is Synced
kubectl get application openpanel -n argocd \
  -o jsonpath='{.status.sync.status}'

# 3. Check that pods with the new image are Running
kubectl get pods -n openpanel
kubectl describe pod -n openpanel <pod-name> | grep Image:

# 4. Check logs of the new version (no errors should appear)
kubectl logs -n openpanel -l app=openpanel-api --tail=50
```

---

## 2. Emergency Rollback

### Rollback via ArgoCD (recommended)

```bash
# 1. View application history
argocd app history openpanel

# 2. Roll back to the previous revision
argocd app rollback openpanel <revision-id>

# 3. Verify that the rollback was applied
kubectl get pods -n openpanel
```

### Blue-Green Rollback (API only, faster)

The script detects the active version and can revert automatically:

```bash
# The script asks for confirmation before switching — respond 'y'
./scripts/blue-green-switch.sh
```

Or manually and immediately:

```bash
# Switch traffic back to Blue instantly
kubectl patch svc openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"blue"}}}'

# Verify
kubectl get svc openpanel-api -n openpanel \
  -o jsonpath='{.spec.selector.version}'
# Should return: blue
```

### Rollback via Git (GitOps)

```bash
# Revert the last CD commit (which updated the image tag)
git log --oneline k8s/apps/base/openpanel/ | head -5
git revert <commit-sha>
git push
# ArgoCD will deploy the previous version automatically
```

---

## 3. Pod in CrashLoopBackOff

```bash
# 1. Identify the problematic pod
kubectl get pods -n openpanel

# 2. View logs from the failed attempt
kubectl logs -n openpanel <pod-name> --previous

# 3. View pod events (reason for failure)
kubectl describe pod -n openpanel <pod-name> | tail -20

# Common causes and solutions:
```

| Cause | Symptom in logs | Solution |
|---|---|---|
| Secret not found | `secret "X" not found` | Reseal: `make sealed-secrets ENV=staging` or `argocd app sync sealed-secrets` |
| Missing environment variable | `Error: missing env DATABASE_URL` | Verify ConfigMap and Secrets |
| Cannot connect to DB | `ECONNREFUSED :5432` | Verify that PostgreSQL is Running and NetworkPolicy allows the connection |
| OOMKilled | `OOMKilled` in reason | Increase memory limit in the resource-limits patch |
| Application error | Stack trace in logs | Review the code, roll back if necessary |

---

## 4. Prometheus Won't Start (TSDB Lock)

**Symptom:** Prometheus in `CrashLoopBackOff` with error in logs:
```
opening storage failed: lock DB directory: resource temporarily unavailable
```

**Cause:** The previous Prometheus process did not release the TSDB directory lock before the new pod tried to start.

**Solution:**

```bash
# DO NOT do a rollout restart (makes the problem worse)
# Delete the pod directly so Kubernetes recreates it cleanly
kubectl delete pod -n observability -l app.kubernetes.io/name=prometheus

# Verify that the new pod starts correctly
kubectl get pods -n observability -w
kubectl logs -n observability -l app.kubernetes.io/name=prometheus --tail=20
```

---

## 5. Alert: Service Down

**Alerts:** `APIDown`, `RedisDown`, `PostgreSQLDown`

```bash
# 1. Verify pod status
kubectl get pods -n openpanel -l app=<service>

# 2. If the pod does not exist or is in error:
kubectl describe pod -n openpanel -l app=<service>
kubectl logs -n openpanel -l app=<service> --previous

# 3. Force pod recreation
kubectl delete pod -n openpanel -l app=<service>

# 4. If it is a StatefulSet (postgres, clickhouse):
kubectl rollout restart statefulset/<name> -n openpanel

# 5. Verify in Prometheus that the target returns to UP
# http://localhost:9090/targets (after port-forward)
```

---

## 6. Alert: High HTTP Error Rate

**Alert:** `HighErrorRate` — more than 10% of requests return 5xx.

```bash
# 1. View API logs in real time
kubectl logs -n openpanel -l app=openpanel-api -f --tail=100

# 2. Prometheus query to see the detail
# rate(http_requests_total{status=~"5.."}[5m])

# 3. Check for database connection errors
kubectl logs -n openpanel -l app=openpanel-api | grep -i "error\|ECONNREFUSED\|timeout"

# 4. Verify database status
kubectl get pods -n openpanel -l app=postgres
kubectl get pods -n openpanel -l app=redis
kubectl get pods -n openpanel -l app=clickhouse

# 5. If the problem persists, consider rollback
argocd app rollback openpanel <previous-revision>
```

---

## 7. Alert: High Memory Usage

**Alert:** `HighMemoryUsage` — a pod exceeds 900MB of memory.

```bash
# 1. Identify which pod has high usage
kubectl top pods -n openpanel
kubectl top pods -n observability

# 2. View configured limits
kubectl describe pod -n openpanel <pod-name> | grep -A4 "Limits:"

# 3. If the pod is being OOMKilled frequently,
#    increase the memory limit in the patch:
# k8s/apps/overlays/staging/patches/api-blue.yaml (or start.yaml / worker.yaml depending on the pod)

# 4. Restart the pod to immediately free memory
kubectl delete pod -n openpanel <pod-name>

# 5. Investigate the cause in Grafana
# Dashboard: OpenPanel K8s Monitoring → Memory Usage by Pod
```

---

## 8. Restore from Backup

**Quick option with the script:**

```bash
# List available backups
./scripts/backup-restore.sh list

# Restore from a backup
./scripts/backup-restore.sh restore daily-full-backup-<timestamp>
```

**Full procedure (manual):**

```bash
# 1. View available backups
velero backup get --namespace velero

# 2. Choose the most recent valid backup
# Backups are named: daily-full-backup-<timestamp>

# 3. Scale deployments to 0 to avoid conflicts
kubectl scale deployment --all -n openpanel --replicas=0

# 4. Start the restore
velero restore create \
  --from-backup daily-full-backup-<timestamp> \
  --namespace velero

# 5. Monitor progress
velero restore describe \
  daily-full-backup-<timestamp>-<restore-ts> \
  --namespace velero

# 6. Wait for the restore to complete (status: Completed)
velero restore get --namespace velero

# 7. Verify that pods start correctly
kubectl get pods -n openpanel -w

# 8. Validate data in the database
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -d openpanel -c "SELECT count(*) FROM users;"
```

---

## 9. Secret Rotation

When it is necessary to change a password or token:

```bash
# 1. Regenerate secrets.yaml with the new credential (the rest use .secrets values or defaults)
make reseal-secrets ENV=staging POSTGRES_PASSWORD=NewSecurePassword123

# 2. Commit and push the encrypted file (safe to commit)
git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
git commit -m "chore: rotate postgres credentials"
git push

# 3. ArgoCD (sealed-secrets app) applies the change automatically.
# The controller creates the new Secret with the updated password.

# 4. Restart the pods that use the secret so they pick up the new value
kubectl rollout restart deployment/openpanel-api-blue -n openpanel
kubectl rollout restart deployment/openpanel-worker -n openpanel

# 5. Verify that pods start with the new credentials
kubectl logs -n openpanel -l app=openpanel-api --tail=30
```

---

## 10. Starting the Cluster from Scratch

Complete procedure when the cluster has been deleted or it is a new environment:

```bash
# 1. Create Minikube cluster (use the script)
./scripts/setup-minikube.sh

# 2. Install Sealed Secrets FIRST (controller + reseal + apply secrets)
make sealed-secrets ENV=staging
# If you have an RSA key backup from the previous cluster, restore it first:
# make restore-sealing-key

# 3. Install ArgoCD (use the script — includes Ingress and HTTP mode)
./scripts/install-argocd.sh
# The script applies the AppProject and bootstrap automatically.
# ArgoCD will sync openpanel, observability, minio, velero, sealed-secrets, namespaces.

# 4. Wait for ArgoCD to sync everything
kubectl get applications -n argocd -w

# 5. Install the Velero server (manual — manages backups)
cat > velero-credentials <<EOF
[default]
aws_access_key_id=$(grep MINIO_USER .secrets | cut -d= -f2)
aws_secret_access_key=$(grep MINIO_PASSWORD .secrets | cut -d= -f2)
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --namespace velero \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000

rm velero-credentials  # do not leave on disk

# 6. Configure local DNS
echo "$(minikube ip -p devops-cluster) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
  | sudo tee -a /etc/hosts

# 7. Verify final status
kubectl get pods -A
kubectl get applications -n argocd
velero schedule get --namespace velero
```

---

## System Health Checklist

Run periodically to verify the general status:

```bash
echo "=== Pods in error ==="
kubectl get pods -A | grep -v Running | grep -v Completed | grep -v NAME

echo "=== ArgoCD sync status ==="
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

echo "=== Recent backups ==="
velero backup get --namespace velero | head -5

echo "=== PVCs ==="
kubectl get pvc -A

echo "=== Resource usage ==="
kubectl top nodes
```
