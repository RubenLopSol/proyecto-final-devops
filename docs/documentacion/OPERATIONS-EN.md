# Operations — Commands and System Management

**Final Project — Master in DevOps & Cloud Computing**

---

## Available Scripts

The repository includes scripts in `scripts/` that automate the most common operations:

| Script | Usage |
|---|---|
| `./scripts/setup-minikube.sh` | Create and configure the Minikube cluster |
| `./scripts/install-argocd.sh` | Install ArgoCD and create the Ingress |
| `./scripts/blue-green-switch.sh` | Blue-Green switch of the API with health checks |
| `./scripts/backup-restore.sh` | Backup and restore (Velero + pg_dump) |

---

## Starting and Stopping the Cluster

```bash
# Start the cluster (openpanel profile)
minikube start -p devops-cluster

# Stop the cluster (data persists)
minikube stop -p devops-cluster

# Cluster status
minikube status -p devops-cluster
```

### Recovery after minikube restart

After a `minikube start`, some pods may end up in `CrashLoopBackOff` or `Init:Error`. The most common is `argocd-repo-server`:

```bash
# 1. Check which pods are not Running
kubectl get pods -A | grep -v "Running\|Completed"

# 2. If argocd-repo-server is in Init:Error, delete it so it is recreated cleanly
kubectl delete pod -n argocd -l app.kubernetes.io/name=repo-server

# 3. If sealed-secrets-controller is in CrashLoopBackOff
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets

# 4. Wait ~30s and verify that all have recovered
kubectl get pods -A | grep -v "Running\|Completed"
```

> **Note:** The `argocd-repo-server` fails on restart because its init container `copyutil` tries to create a symbolic link that already exists from the previous startup. Deleting the pod causes Kubernetes to recreate it with a clean state.

---

## Cluster Management

```bash
# General cluster status
minikube status
kubectl cluster-info
kubectl get nodes

# View all system pods
kubectl get pods -A

# View pods by namespace
kubectl get pods -n openpanel
kubectl get pods -n observability
kubectl get pods -n argocd
kubectl get pods -n velero
kubectl get pods -n backup
```

---

## Application Management (namespace: openpanel)

### Viewing resource status

```bash
# Pods, services, deployments and ingress
kubectl get all -n openpanel

# View logs of a service
kubectl logs -n openpanel -l app=openpanel-api --tail=100 -f
kubectl logs -n openpanel -l app=openpanel-start --tail=100 -f
kubectl logs -n openpanel -l app=openpanel-worker --tail=100 -f

# Database logs
kubectl logs -n openpanel -l app=postgres --tail=50
kubectl logs -n openpanel -l app=redis --tail=50
kubectl logs -n openpanel -l app=clickhouse --tail=50
```

### Restarting a service

```bash
# Rolling restart (without downtime)
kubectl rollout restart deployment/openpanel-api-blue -n openpanel
kubectl rollout restart deployment/openpanel-start -n openpanel
kubectl rollout restart deployment/openpanel-worker -n openpanel

# Verify the rollout
kubectl rollout status deployment/openpanel-api-blue -n openpanel
```

### Scaling services

```bash
# Scale API Blue to 3 replicas
kubectl scale deployment openpanel-api-blue -n openpanel --replicas=3

# Scale the Worker
kubectl scale deployment openpanel-worker -n openpanel --replicas=2

# View scaling in real time
kubectl get pods -n openpanel -w
```

---

## Blue-Green — API Traffic Switch

### With the script (recommended)

```bash
# Detects the active version, scales the new one, verifies health and switches with confirmation
./scripts/blue-green-switch.sh
```

See full script documentation in [BLUE-GREEN-EN.md](BLUE-GREEN-EN.md#switch-script----blue-green-switchsh).

### Manual

```bash
# View currently active version
kubectl get svc openpanel-api -n openpanel \
  -o jsonpath='{.spec.selector.version}'

# Switch to Green
kubectl patch svc openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"green"}}}'

# Rollback to Blue
kubectl patch svc openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"blue"}}}'

# View active pods by version
kubectl get pods -n openpanel -l version=blue
kubectl get pods -n openpanel -l version=green
```

---

## Observability — Tool Access

### Grafana

```bash
kubectl port-forward svc/grafana -n observability 3000:3000
# http://localhost:3000
# User: admin | Password: see Secret grafana-admin-credentials
kubectl get secret grafana-admin-credentials -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### Prometheus

```bash
kubectl port-forward svc/prometheus -n observability 9090:9090
# http://localhost:9090
# Targets: http://localhost:9090/targets
# Alerts: http://localhost:9090/alerts
```

### ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# https://localhost:8080
# User: admin | Password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## ArgoCD — Deployment Management

> **Prerequisite:** log in with the CLI before using `argocd` commands:
> ```bash
> kubectl port-forward svc/argocd-server -n argocd 8080:80 &
> argocd login localhost:8080 --insecure \
>   --username admin \
>   --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
>     -o jsonpath="{.data.password}" | base64 -d)
> ```

```bash
# View status of all applications
kubectl get applications -n argocd
argocd app list

# Manually sync an app
argocd app sync openpanel
argocd app sync observability
argocd app sync minio
argocd app sync velero
argocd app sync sealed-secrets
argocd app sync namespaces

# View differences between Git and the cluster
argocd app diff openpanel

# View deployment history
argocd app history openpanel

# Roll back to a previous version
argocd app rollback openpanel <revision-id>

# Force full synchronization
argocd app sync openpanel --force --prune
```

---

## Backups — Management with Velero

### With the script (recommended)

```bash
# Full backup of the openpanel namespace
./scripts/backup-restore.sh backup openpanel

# Direct backup of PostgreSQL and Redis (pg_dump + redis SAVE)
./scripts/backup-restore.sh backup-db

# List available backups
./scripts/backup-restore.sh list

# Restore from a backup
./scripts/backup-restore.sh restore <backup-name>
```

See full script documentation in [BACKUP-RECOVERY-EN.md](BACKUP-RECOVERY-EN.md#operations-script----backup-restoresh).

### Manual (direct velero commands)

```bash
# View configured schedules
velero schedule get --namespace velero

# View available backups
velero backup get --namespace velero

# Create manual backup
velero backup create backup-manual-$(date +%Y%m%d-%H%M) \
  --include-namespaces openpanel \
  --namespace velero

# View backup status
velero backup describe <backup-name> --namespace velero

# Restore from a backup
velero restore create \
  --from-backup <backup-name> \
  --namespace velero
```

---

## Secrets — Management with Sealed Secrets

```bash
# Regenerate all encrypted secrets (after rotating credentials or recreating the cluster)
make reseal-secrets ENV=staging

# Rotate a specific credential
make reseal-secrets ENV=staging POSTGRES_PASSWORD=new-pass

# Verify that the controller is active
kubectl get pods -n sealed-secrets

# View decrypted secrets in the namespaces
kubectl get secrets -n openpanel
kubectl get secrets -n observability
kubectl get secrets -n backup
```

---

## Direct Database Access

### PostgreSQL

```bash
# Get password
kubectl get secret postgres-credentials -n openpanel \
  -o jsonpath='{.data.postgres-password}' | base64 -d

# Connect via psql
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -d openpanel
```

### Redis

```bash
# Connect to Redis CLI
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=redis -o jsonpath='{.items[0].metadata.name}') \
  -c redis -- redis-cli

# Inside Redis CLI:
# INFO server
# DBSIZE
# LLEN bull:default:wait
```

### ClickHouse

```bash
# Connect to the ClickHouse client
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=clickhouse -o jsonpath='{.items[0].metadata.name}') \
  -- clickhouse-client

# Inside the client:
# SHOW DATABASES;
# SELECT count() FROM openpanel.events;
```

---

## Resource Monitoring

```bash
# Resource usage by pod (requires metrics-server)
kubectl top pods -n openpanel
kubectl top pods -n observability

# Resource usage by node
kubectl top nodes

# View PVCs and their status
kubectl get pvc -A

# View available PVs
kubectl get pv
```

---

## Quick Troubleshooting

```bash
# Pod in CrashLoopBackOff — view logs of the failed container
kubectl logs -n <namespace> <pod-name> --previous

# Pod in Pending — view events
kubectl describe pod -n <namespace> <pod-name>

# ImagePullBackOff — verify the image exists
kubectl get pod -n <namespace> <pod-name> -o jsonpath='{.spec.containers[0].image}'

# View all namespace events (sorted by date)
kubectl get events -n openpanel --sort-by=.metadata.creationTimestamp

# Describe a deployment to view full status
kubectl describe deployment openpanel-api-blue -n openpanel
```
