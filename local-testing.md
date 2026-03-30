# Local Testing Guide

How to deploy, verify, and troubleshoot everything locally before pushing to the repository.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Credentials you need before starting](#credentials-you-need-before-starting)
3. [Step-by-step cluster setup](#step-by-step-cluster-setup)
4. [Connection verification](#connection-verification)
5. [Troubleshooting: all known issues and fixes](#troubleshooting-all-known-issues-and-fixes)
6. [Scripts reference](#scripts-reference)
7. [Starting from scratch](#starting-from-scratch)
8. [Testing the CI pipeline locally with act](#testing-the-ci-pipeline-locally-with-act)
9. [Testing individual checks without act](#testing-individual-checks-without-act)
10. [Testing AlertManager locally](#testing-alertmanager-locally-without-slack)
11. [Testing the full GitOps flow locally](#testing-the-full-gitops-flow-locally)
12. [Testing the blue-green switch locally](#testing-the-blue-green-switch-locally)
13. [Testing backup and restore locally](#testing-backup-and-restore-locally)
14. [Quick sanity check before any push](#quick-sanity-check-before-any-push)

---

## Prerequisites

Install these tools before starting:

| Tool | Minimum version | Purpose | Install (Linux) |
|---|---|---|---|
| `minikube` | v1.31 | Local Kubernetes cluster | [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io/docs/start/) |
| `kubectl` | v1.28 | Kubernetes CLI | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | v3.8 | Kubernetes package manager | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |
| `docker` | any | Container runtime + Minikube driver | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| `gh` | any | GitHub CLI (used by `make setup-github`) | `sudo apt install gh` |
| `argocd` | any | ArgoCD CLI | [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io/en/stable/cli_installation/) |
| `kubeseal` | any | Sealed Secrets CLI | [github.com/bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets#kubeseal) |
| `velero` | any | Backup CLI | [velero.io/docs/latest/basic-install](https://velero.io/docs/latest/basic-install/) |
| `act` | any | Run GitHub Actions locally | `curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh \| bash` |
| `kubeconform` | any | Validate K8s manifests | `go install github.com/yannh/kubeconform/cmd/kubeconform@latest` |
| `kustomize` | any | Build K8s overlays | `curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" \| bash` |
| `kube-linter` | any | Lint K8s manifests | `go install golang.stackrox.io/kube-linter/cmd/kube-linter@latest` |
| `hadolint` | any | Lint Dockerfiles | `wget -O /usr/local/bin/hadolint https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64 && chmod +x /usr/local/bin/hadolint` |
| `gitleaks` | any | Scan for secrets | `go install github.com/zricethezav/gitleaks/v8@latest` |
| `trivy` | any | Scan container images | [aquasecurity.github.io/trivy](https://aquasecurity.github.io/trivy/latest/getting-started/installation/) |

> `setup-minikube.sh` checks Minikube ≥ v1.31 automatically.
> `install-argocd.sh` checks Helm ≥ v3.8 automatically.
> Both fail early with a clear error and upgrade link if the version is not met.

---

## Credentials you need before starting

Before running any setup command you need two sets of credentials. This section explains exactly where each one comes from.

---

### 1. GitHub Token (for `make all`, `act`, and the CD pipeline)

The GitHub token is used in several places:

| Where | Why |
|---|---|
| `make all GITHUB_TOKEN=...` | Logs in to GHCR, creates the repo, sets workflow permissions, creates `REGISTRY_OWNER` variable |
| `make docker-login` | `docker login ghcr.io` to push images |
| `act` (local CI) | The `GITHUB_TOKEN` secret that GitHub Actions injects automatically — `act` needs a real token to simulate it |
| `cd-update-tags.yml` | Pushes the updated image tag commit back to the repo (`contents: write`) |

**How to generate a new token:**

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token (classic)**
3. Select these scopes:
   - `repo` (full control — needed for pushing commits and creating tags)
   - `write:packages` (push images to GHCR)
   - `read:packages`
4. Click **Generate token** — copy it immediately, it is shown only once

```bash
# Save it to a local env var so you don't have to type it on every make command
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx

# Then use it
make all GITHUB_USER=rubenlopsol GITHUB_TOKEN=${GITHUB_TOKEN}
```

**Where to put the token:**

| Location | What to replace | When needed |
|---|---|---|
| Shell env var | `export GITHUB_TOKEN=ghp_xxx` | Every terminal session where you run `make` |
| `.secrets` file at repo root | `GITHUB_TOKEN=ghp_xxx` | Running `act` locally |
| GitHub repo → Settings → Secrets | Not needed — the token is passed via `make setup-github` automatically | CI/CD pipelines read `GITHUB_TOKEN` from Actions context |

**Important — `REGISTRY_OWNER` variable:**

`make setup-github` automatically creates a GitHub Actions variable called `REGISTRY_OWNER` (lowercase GitHub username) in your repository. The CI/CD workflows use this variable instead of `github.actor` to push images to GHCR. If you recreate the repo or the variable disappears, recreate it manually:

```bash
gh variable set REGISTRY_OWNER \
  --repo <your-user>/<repo-name> \
  --body "<your-github-username-lowercase>"
```

For `act`, create a `.secrets` file at the repo root (already in `.gitignore`):

```bash
# .secrets — never commit this file
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

```bash
# Then run act pointing at the secrets file
act push --workflows .github/workflows/ci-validate.yml --secret-file .secrets
```

---

### 2. Velero / MinIO Credentials

Velero stores backups in MinIO (the S3-compatible object storage that runs inside the cluster). Both MinIO and Velero must use the **same** credentials — MinIO uses them to authenticate incoming requests, and Velero uses them to make those requests.

#### Where the credentials live

| File / Resource | Purpose |
|---|---|
| `k8s/argocd/sealed-secrets/minio-credentials.yaml` | SealedSecret — MinIO reads `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` from this |
| `credentials-velero` | Plain-text file on your machine — Velero CLI reads it at install time |

The two must match. On a new cluster the SealedSecrets are re-sealed automatically by `make reseal-secrets` (called inside `make sealed-secrets`). The MinIO credentials default to `minioadmin`/`minioadmin`. The `credentials-velero` file must match.

#### For a first-time local setup (new cluster)

```bash
cp credentials-velero.example credentials-velero

# The file should look like:
# [default]
# aws_access_key_id = minioadmin
# aws_secret_access_key = minioadmin
```

> The defaults used by `make reseal-secrets` are `minioadmin`/`minioadmin` for MinIO. If you want different credentials, run `make reseal-secrets` with custom env vars or re-seal manually after changing the values in the Makefile.

**Install Velero using the same credentials:**

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000
```

#### If you are using the original cluster (not a new one)

```bash
# Decode credentials from the running secret if you have cluster access
kubectl get secret minio-credentials -n backup \
  -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d

kubectl get secret minio-credentials -n backup \
  -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d
```

Then fill `credentials-velero` with those values.

---

## Step-by-step cluster setup

This section walks through every setup step in order, explains what each command does, and tells you exactly what to verify before moving to the next step.

> ⚠️ Do **not** skip the verification steps. Each step has known failure modes that are only visible if you check.

---

### Step 1: Create the cluster

```bash
make cluster
# or directly:
./scripts/setup-minikube.sh
```

**What happens:**
- Creates a Minikube cluster named `openpanel` using the Docker driver
- Kubernetes v1.28.0, 6 CPUs, 8 GB RAM, 60 GB disk
- Enables addons: `ingress`, `metrics-server`, `storage-provisioner`
- Creates namespaces: `openpanel`, `observability`, `backup`, `argocd`
- Appends cluster IP entries to `/etc/hosts` for all `.local` domains

Idempotent — if the cluster already exists it skips creation and updates `/etc/hosts` with the current IP.

**Verify:**

```bash
minikube status -p openpanel
# Expected:
# openpanel
# type: Control Plane
# host: Running
# kubelet: Running
# apiserver: Running
# kubeconfig: Configured

kubectl get namespaces
# Expected: openpanel, observability, backup, argocd all present

grep openpanel.local /etc/hosts
# Expected: lines like "192.168.49.2  openpanel.local api.openpanel.local grafana.local ..."
```

---

### Step 2: Install ArgoCD

```bash
make argocd
# or directly:
./scripts/install-argocd.sh
```

**What happens:**
1. Validates Helm ≥ v3.8
2. Adds the ArgoCD Helm repo and installs/upgrades to chart version 7.7.0 with values from `k8s/helm/values/argocd.yaml`
3. Waits for the `argocd-initial-admin-secret` to be available
4. Prints the access URL, username, and initial password

**Verify:**

```bash
kubectl get pods -n argocd
# Expected: all pods in Running state (argocd-server, argocd-repo-server,
#           argocd-application-controller, argocd-dex-server, argocd-redis)

# Get the admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
# Expected: a random string — this is the admin password

curl -k http://argocd.local
# Expected: HTML response (ArgoCD login page)
# Or open http://argocd.local in the browser, login: admin / <password above>
```

---

### Step 3: Install Sealed Secrets and re-seal

```bash
make sealed-secrets
```

**What happens:**
1. Adds the Sealed Secrets Helm repo and installs the controller into the `sealed-secrets` namespace
2. Waits for the controller pod to be ready
3. **Automatically calls `make reseal-secrets`** — this fetches the new cluster's public cert and re-seals all secrets with default dev values (see below)
4. Applies the re-sealed `k8s/argocd/sealed-secrets/*.yaml` files to the cluster

> ⚠️ This step is critical on every fresh cluster. Each new Minikube cluster generates a new Sealed Secrets key pair. The `.yaml` files committed in the repo were sealed with a previous cluster's key and **cannot** be decrypted by a new cluster. `make reseal-secrets` re-seals them automatically with the current cluster's key. See [Issue A](#issue-a--sealed-secrets-encrypted-with-old-cluster-key) for the full explanation.

**Default values used by `make reseal-secrets`:**

| Secret name | Keys and default values |
|---|---|
| `postgres-credentials` | `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=postgres`, `POSTGRES_DB=openpanel` |
| `redis-credentials` | `REDIS_PASSWORD=redis` |
| `clickhouse-credentials` | `CLICKHOUSE_PASSWORD=clickhouse` |
| `openpanel-secrets` | `DATABASE_URL`, `DATABASE_URL_DIRECT` (both pointing to postgres), `REDIS_URL`, `SECRET_KEY`, `CLICKHOUSE_URL` |
| `grafana-admin-credentials` | `admin-user=admin`, `admin-password=admin` |
| `minio-credentials` | `MINIO_ROOT_USER=minioadmin`, `MINIO_ROOT_PASSWORD=minioadmin` |

**Verify:**

```bash
kubectl get pods -n sealed-secrets
# Expected: 1/1 Running

kubectl get sealedsecrets -n openpanel
# Expected: all show SYNCED: True
# Bad state: "no key could decrypt secret" means re-seal did not work

kubectl get secrets -n openpanel
# Expected: postgres-credentials, redis-credentials, clickhouse-credentials,
#           openpanel-secrets all present

kubectl get secrets -n observability
# Expected: grafana-admin-credentials present

kubectl get secrets -n backup
# Expected: minio-credentials present
```

---

### Step 4: Install kube-prometheus-stack CRDs (first time only)

> ⚠️ This step must be done before or immediately after the first ArgoCD sync attempt on a fresh cluster. kube-prometheus-stack v65 CRDs are too large for client-side apply and will fail inside ArgoCD without pre-installation. See [Issue F](#issue-f--kube-prometheus-stack-crds-too-large-for-client-side-apply) for details.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm show crds prometheus-community/kube-prometheus-stack --version 65.1.1 | \
  kubectl apply --server-side --force-conflicts -f -
# Expected: many "configured" or "created" lines, no errors
```

If this step is skipped and ArgoCD already tried to sync, force-apply the CRDs and then trigger a re-sync:

```bash
helm show crds prometheus-community/kube-prometheus-stack --version 65.1.1 | \
  kubectl apply --server-side --force-conflicts -f -

argocd app sync observability-prometheus --grpc-web
```

---

### Step 5: Apply ArgoCD apps and wait for DB migrations

```bash
make argocd-apps
```

**What happens:**
1. Applies the AppProject (`k8s/argocd/projects/openpanel-project.yaml`)
2. Applies all Application manifests from `k8s/argocd/applications/`
3. ArgoCD begins syncing all apps. The `openpanel` app has `PreSync` hooks — **the migration job runs before any pod is created**

> ⚠️ Do not skip waiting for the migration job to complete. If it fails, the worker and API pods will crash because the database tables do not exist. See [Issue C](#issue-c--database-migrations-never-run--worker-crashloopbackoff) for details.

**Verify:**

```bash
# Watch all apps reach Synced state
kubectl get applications -n argocd -w
# Expected: all apps show SYNC STATUS: Synced, HEALTH STATUS: Healthy

# Verify the migration job completed successfully
kubectl get job openpanel-migrate -n openpanel
# Expected: COMPLETIONS shows 1/1

kubectl logs job/openpanel-migrate -n openpanel
# Expected: last line contains "All migrations have been successfully applied"

# Verify all OpenPanel pods are running
kubectl get pods -n openpanel
# Expected: all pods in Running state, no CrashLoopBackOff

# Check the API is healthy (all dependencies reachable)
API_POD=$(kubectl get pod -n openpanel -l app=openpanel-api,version=blue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openpanel $API_POD -- \
  node -e "fetch('http://localhost:3000/healthcheck').then(r=>r.json()).then(console.log)"
# Expected: {"ready":true,"redis":true,"db":true,"ch":true}
```

---

### Step 6: Open all UIs

```bash
make open
# Opens: http://argocd.local, http://openpanel.local, http://grafana.local,
#         http://prometheus.local in the browser
```

Or navigate manually:

| UI | URL | Default credentials |
|---|---|---|
| ArgoCD | http://argocd.local | admin / (see step 2 verify) |
| OpenPanel | http://openpanel.local | (set during first login) |
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | (no auth) |

---

### What `make all` runs internally

Running `make all GITHUB_USER=<user> GITHUB_TOKEN=<token>` executes all steps in order:

```bash
make setup-github     # 1. creates GitHub repo, sets REGISTRY_OWNER variable, pushes code
make docker-login     # 2. docker login to GHCR
make cluster          # 3. creates Minikube cluster and configures /etc/hosts
make argocd           # 4. installs ArgoCD via Helm
make sealed-secrets   # 5. installs Sealed Secrets controller + calls reseal-secrets automatically
make argocd-apps      # 6. applies AppProject and ArgoCD Application definitions
make open             # 7. opens all UIs in the browser
```

> Note: The CRD pre-installation step (Step 4 above) is **not** part of `make all`. Run it manually after `make argocd` and before `make argocd-apps`, or run it after ArgoCD fails the first sync and then trigger a re-sync.

---

## Connection verification

Use these checks to confirm every service is talking to every other service. Run them after the full setup completes.

---

### API healthcheck (checks all dependencies at once)

```bash
API_POD=$(kubectl get pod -n openpanel -l app=openpanel-api,version=blue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n openpanel $API_POD -- \
  node -e "fetch('http://localhost:3000/healthcheck').then(r=>r.json()).then(console.log)"
# Expected: {"ready":true,"redis":true,"db":true,"ch":true}
```

If `ready` is `false`, check each dependency individually below.

---

### API → PostgreSQL

```bash
# Via healthcheck
kubectl exec -n openpanel $API_POD -- \
  node -e "fetch('http://localhost:3000/healthcheck').then(r=>r.json()).then(d=>console.log('DB:', d.db))"
# Expected: DB: true

# Verify tables exist directly (checks that migrations ran)
kubectl exec -it -n openpanel postgres-0 -c postgres -- \
  psql -U postgres -d openpanel -c "\dt" 2>/dev/null | grep salts
# Expected: line containing "salts" — if missing, migrations did not run (see Issue C)
```

---

### API → ClickHouse

```bash
# Via healthcheck
kubectl exec -n openpanel $API_POD -- \
  node -e "fetch('http://localhost:3000/healthcheck').then(r=>r.json()).then(d=>console.log('ClickHouse:', d.ch))"
# Expected: ClickHouse: true

# Direct ClickHouse version check
kubectl exec -n openpanel clickhouse-0 -- clickhouse-client --query "SELECT version()"
# Expected: 24.12.x.x

# If ch: false, check for the incompatible setting error (see Issue D)
kubectl logs -n openpanel $API_POD | grep "query_plan_convert_any_join"
# If this line appears, the CLICKHOUSE_SETTINGS_REMOVE_CONVERT_ANY_JOIN fix is missing
```

---

### API → Redis

```bash
# Via healthcheck
kubectl exec -n openpanel $API_POD -- \
  node -e "fetch('http://localhost:3000/healthcheck').then(r=>r.json()).then(d=>console.log('Redis:', d.redis))"
# Expected: Redis: true

# Direct Redis check
REDIS_POD=$(kubectl get pod -n openpanel -l app=redis -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n openpanel $REDIS_POD -c redis -- redis-cli -a redis ping
# Expected: PONG
```

---

### Prometheus scrape targets

```bash
kubectl port-forward -n observability svc/prometheus-operated 9090:9090 &

curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import sys,json; targets=json.load(sys.stdin)['data']['activeTargets']; \
  print('up:', sum(1 for t in targets if t['health']=='up'), \
  '/ down:', sum(1 for t in targets if t['health']!='up'))"
# Expected: mostly "up" entries

# Or open browser: http://prometheus.local → Status → Targets
```

---

### Prometheus → AlertManager

```bash
kubectl port-forward -n observability svc/alertmanager-operated 9093:9093 &

curl -s http://localhost:9093/-/healthy
# Expected: OK

# Verify AlertManager appears in Prometheus
curl -s http://localhost:9090/api/v1/alertmanagers | python3 -m json.tool
# Expected: alertmanager URL listed as active
```

---

### Grafana → Prometheus datasource

```bash
# Get Grafana admin password
kubectl get secret -n observability grafana-admin-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Open browser: http://grafana.local
# Login: admin / <password above>
# Go to: Connections → Data Sources → prometheus → Test
# Expected: green checkmark "Data source is working"
```

---

### Grafana → Loki datasource

```bash
kubectl get pods -n observability | grep loki
# Expected: loki pod Running

# In Grafana UI: Connections → Data Sources → loki → Test
# Expected: green checkmark
```

---

### ArgoCD → Git repo

```bash
argocd app list --grpc-web
# Expected: all apps show SYNC STATUS: Synced, HEALTH STATUS: Healthy

# Detail per app
argocd app get openpanel --grpc-web
argocd app get observability-prometheus --grpc-web
```

---

### Ingress end-to-end

```bash
curl -s -o /dev/null -w "%{http_code}" http://openpanel.local/
# Expected: 200 or 302

curl -s http://api.openpanel.local/healthcheck
# Expected: {"ready":true,...}

curl -s -o /dev/null -w "%{http_code}" http://grafana.local/
# Expected: 200

curl -s -o /dev/null -w "%{http_code}" http://prometheus.local/
# Expected: 200

curl -sk -o /dev/null -w "%{http_code}" http://argocd.local/
# Expected: 200
```

---

## Troubleshooting: all known issues and fixes

This section documents every issue encountered during local testing of this project. Each entry has: symptom, root cause, and the exact fix applied.

---

### Issue A — Sealed Secrets encrypted with old cluster key

**Symptom:**
- All pods in `openpanel` namespace stuck in `CreateContainerConfigError`
- `kubectl get sealedsecrets -n openpanel` shows `no key could decrypt secret`
- `kubectl describe sealedsecret <name> -n openpanel` shows the error in Events

**Root cause:**

Each fresh Minikube cluster generates a new Sealed Secrets key pair when the controller starts. The `.yaml` files committed in `k8s/argocd/sealed-secrets/` were sealed with the previous cluster's key. The new controller cannot decrypt them.

**Fix:**

`make reseal-secrets` fetches the current cluster's certificate and re-seals all secrets with known dev defaults. It is now called automatically inside `make sealed-secrets` — you should not need to run it manually unless you deleted and recreated the cluster without re-running the full setup.

```bash
# Manual re-seal (if needed after cluster recreation without full setup)
make reseal-secrets

# Then re-apply the sealed secrets
kubectl apply -f k8s/argocd/sealed-secrets/
```

**Verify:**

```bash
kubectl get sealedsecrets -n openpanel
# All show SYNCED: True

kubectl get secrets -n openpanel
# postgres-credentials, redis-credentials, openpanel-secrets, clickhouse-credentials present
```

---

### Issue B — DATABASE_URL_DIRECT missing from Prisma schema

**Symptom:**

Migration job fails with:

```
Error: Environment variable not found: DATABASE_URL_DIRECT.
  --> schema.prisma:19
```

**Root cause:**

The Prisma schema in `/app/packages/db/schema.prisma` uses two database URLs:
- `DATABASE_URL` — used for connection pooling (PgBouncer / regular connections)
- `DATABASE_URL_DIRECT` — used for migrations, which cannot go through a connection pool

The original sealed secret only contained `DATABASE_URL`. Prisma errors out at startup if `DATABASE_URL_DIRECT` is not set.

**Fix:**

`DATABASE_URL_DIRECT` was added to `openpanel-secrets` SealedSecret in `make reseal-secrets`. For a single-node local setup it is set to the same value as `DATABASE_URL` (direct connection to PostgreSQL, no PgBouncer). The fix is already in `k8s/argocd/sealed-secrets/openpanel-secrets.yaml` after running `make reseal-secrets`.

**Verify:**

```bash
kubectl get secret openpanel-secrets -n openpanel \
  -o jsonpath='{.data.DATABASE_URL_DIRECT}' | base64 -d
# Expected: postgres://postgres:postgres@postgres:5432/openpanel (or similar)
```

---

### Issue C — Database migrations never run — worker CrashLoopBackOff

**Symptom:**

`openpanel-worker` in `CrashLoopBackOff`, logs show:

```
Error: The table `public.salts` does not exist in the current database.
  code: 'P2021'
```

**Root cause:**

OpenPanel's Docker image does not run `prisma migrate deploy` on startup. The database tables are never created. Kubernetes starts the worker, it tries to query `public.salts`, fails, and crashes.

**Fix:**

`k8s/base/openpanel/migrate-job.yaml` — a Kubernetes Job with an ArgoCD `PreSync` hook annotation. It runs before every deployment and executes `prisma migrate deploy` against the PostgreSQL database:

```yaml
annotations:
  argocd.argoproj.io/hook: PreSync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

The job runs `node_modules/.bin/prisma migrate deploy` from the working directory `/app/packages/db`.

**Verify:**

```bash
kubectl get job openpanel-migrate -n openpanel
# Expected: COMPLETIONS 1/1

kubectl logs job/openpanel-migrate -n openpanel
# Expected: ends with "All migrations have been successfully applied"

# Confirm tables exist
kubectl exec -it -n openpanel postgres-0 -c postgres -- \
  psql -U postgres -d openpanel -c "\dt"
# Expected: list of tables including salts, events, projects, etc.
```

**If the migration job fails:**

```bash
# Check the job logs
kubectl logs job/openpanel-migrate -n openpanel

# Common cause: openpanel-secrets not yet created (Sealed Secrets not installed / not synced)
kubectl get secret openpanel-secrets -n openpanel
# If missing: run make sealed-secrets first

# Delete the failed job so ArgoCD can create a new one on next sync
kubectl delete job openpanel-migrate -n openpanel
argocd app sync openpanel --grpc-web
```

---

### Issue D — ClickHouse 24.x incompatibility

**Symptom:**

API pods running but not ready:
- Readiness probe returns 503: `{"ready":false,"reason":"dependencies not ready"}`
- API pod logs full of:

```
Setting query_plan_convert_any_join_to_semi_or_anti_join is neither a builtin setting nor a custom setting
```

**Root cause:**

The deployed ClickHouse version is `24.12`. The setting `query_plan_convert_any_join_to_semi_or_anti_join` was introduced in ClickHouse 25.x. The upstream OpenPanel API client unconditionally sends this setting on every query. ClickHouse 24.x rejects it as unknown, causing all ClickHouse queries to fail.

**Fix:**

Added `CLICKHOUSE_SETTINGS_REMOVE_CONVERT_ANY_JOIN: "true"` to `k8s/base/openpanel/configmap.yaml`. When this env var is set, the API client skips the incompatible setting. The configmap is already committed — no action needed on a fresh clone.

```bash
# Verify the fix is present in the configmap
kubectl get configmap openpanel-config -n openpanel -o yaml | grep CLICKHOUSE_SETTINGS
# Expected: CLICKHOUSE_SETTINGS_REMOVE_CONVERT_ANY_JOIN: "true"
```

**Verify the fix works:**

```bash
API_POD=$(kubectl get pod -n openpanel -l app=openpanel-api,version=blue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n openpanel $API_POD -- \
  node -e "fetch('http://localhost:3000/healthcheck').then(r=>r.json()).then(console.log)"
# Expected: {"ready":true,"redis":true,"db":true,"ch":true}
```

---

### Issue E — ArgoCD reverts manual configmap fixes

**Symptom:**

Manual `kubectl apply` of a configmap fix gets reverted within seconds. Even patching the ArgoCD Application object itself gets reverted.

**Root cause:**

The openpanel ArgoCD Application has `selfHeal: true`. ArgoCD continuously reconciles everything back to what's in git. The bootstrap App of Apps pattern means even the Application object is managed by ArgoCD — so patching the Application also gets reverted.

**Fix:**

The correct fix is to commit the change to the branch being tracked by the ArgoCD app (`targetRevision` in `k8s/argocd/applications/openpanel-app.yaml`).

For temporary testing on a feature branch without changing `master`:

```bash
# 1. Disable auto-sync on the bootstrap app (prevents it from reverting the openpanel app)
argocd app set bootstrap --sync-policy none --grpc-web

# 2. Change targetRevision in the openpanel Application to your test branch
# Edit k8s/argocd/applications/openpanel-app.yaml:
#   targetRevision: your-test-branch

# 3. Apply the change directly (since bootstrap auto-sync is now disabled)
kubectl apply -f k8s/argocd/applications/openpanel-app.yaml

# 4. Push your configmap fix to your test branch
git push origin your-test-branch

# 5. Trigger a sync
argocd app sync openpanel --grpc-web

# 6. When done, re-enable auto-sync on bootstrap
argocd app set bootstrap --sync-policy automated --grpc-web
```

---

### Issue F — kube-prometheus-stack CRDs too large for client-side apply

**Symptom:**

`observability-prometheus` ArgoCD app stuck at `OutOfSync/Missing`:

```
CustomResourceDefinition.apiextensions.k8s.io "alertmanagers.monitoring.coreos.com"
is invalid: metadata.annotations: Too long: must have at most 262144 bytes
```

**Root cause:**

kube-prometheus-stack v65 CRDs are very large. `kubectl apply` (client-side) stores the full manifest in the `last-applied-configuration` annotation, which pushes the annotation over the 262144-byte limit.

**Fix 1 (already applied):** `ServerSideApply=true` is set in `syncOptions` in `k8s/argocd/applications/observability-prometheus-app.yaml`. ArgoCD will use server-side apply, which does not store the annotation.

**Fix 2 (run once on a fresh cluster):** Pre-install the CRDs with server-side apply before ArgoCD tries to sync:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm show crds prometheus-community/kube-prometheus-stack --version 65.1.1 | \
  kubectl apply --server-side --force-conflicts -f -
```

> Run Fix 2 before applying the ArgoCD apps, or after ArgoCD fails the first time. Then trigger `argocd app sync observability-prometheus --grpc-web`.

---

### Issue G — ArgoCD AppProject too restrictive for kube-prometheus-stack

**Symptom:**

Sync fails with:

```
resource apiextensions.k8s.io:CustomResourceDefinition is not permitted in project openpanel
namespace kube-system is not permitted in project openpanel
```

**Root cause:**

kube-prometheus-stack deploys:
- CRDs (cluster-scoped, `apiextensions.k8s.io`)
- Resources into `kube-system` (e.g., node exporter DaemonSet)
- Admission webhooks (`admissionregistration.k8s.io`)
- Broad RBAC resources

The original AppProject only permitted a limited set of namespaces and resource groups.

**Fix (already applied):** `k8s/argocd/projects/openpanel-project.yaml` was updated to add:
- `kube-system` to destinations
- `apiextensions.k8s.io/CustomResourceDefinition` to `clusterResourceWhitelist`
- `admissionregistration.k8s.io` MutatingWebhookConfiguration and ValidatingWebhookConfiguration to `clusterResourceWhitelist`
- `rbac.authorization.k8s.io/*`, `monitoring.coreos.com/*`, `policy/*`, `autoscaling/*` to `namespaceResourceWhitelist`

No action needed — the fix is committed. If you see this error again, compare `k8s/argocd/projects/openpanel-project.yaml` against the resource that failed and add the missing entry.

---

### Issue H — Prometheus operator TLS webhook cert stale after fresh cluster

**Symptom:**

- Prometheus operator pod logs full of `TLS handshake error: bad certificate`
- Prometheus StatefulSet never created
- New operator pod stuck in `ContainerCreating` with:

```
MountVolume.SetUp failed for volume "tls-secret":
secret "observability-prometheus-k-admission" not found
```

**Root cause:**

On a fresh cluster the admission webhook TLS certificate (stored in the secret `observability-prometheus-k-admission`) was generated for the old cluster's CA. After reinstalling kube-prometheus-stack on a new cluster, the certificate needs to be regenerated using an admission-create job.

**Fix:**

```bash
# 1. Delete the stale TLS secret
kubectl delete secret observability-prometheus-k-admission -n observability

# 2. Delete the stale webhook configurations
kubectl delete validatingwebhookconfiguration \
  observability-prometheus-k-admission 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration \
  observability-prometheus-k-admission 2>/dev/null || true

# 3. Run the admission-create job to regenerate the certificate
# Extract just the admission-create job from the Helm chart and apply it:
helm template observability-prometheus prometheus-community/kube-prometheus-stack \
  -n observability \
  -f k8s/helm/values/kube-prometheus-stack.yaml \
  --version 65.1.1 | \
python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(sys.stdin))
for d in docs:
    if d and d.get('kind') == 'Job' and 'admission-create' in d.get('metadata',{}).get('name',''):
        print('---')
        print(yaml.dump(d))
" | kubectl apply -f -

# 4. Wait for the job to complete
kubectl wait --for=condition=complete job \
  -l app=kube-prometheus-stack-admission-create \
  -n observability --timeout=60s

# 5. If the operator pod was stuck in ContainerCreating, delete it to force a restart
kubectl delete pod -n observability \
  -l app.kubernetes.io/name=kube-prometheus-stack-operator

# 6. Verify the operator pod comes up cleanly
kubectl get pods -n observability -w
# Expected: operator pod Running, no TLS errors in logs
kubectl logs -n observability \
  $(kubectl get pod -n observability \
    -l app.kubernetes.io/name=kube-prometheus-stack-operator \
    -o jsonpath='{.items[0].metadata.name}') | grep -i error | head -5
# Expected: no TLS handshake errors
```

---

## Scripts reference

Each script has a specific role in the deployment lifecycle:

```
1. setup-minikube.sh       ← Run once: creates cluster, namespaces, and configures /etc/hosts
2. install-argocd.sh       ← Run once: installs ArgoCD via Helm and bootstraps App of Apps
3. blue-green-switch.sh    ← Run manually when promoting a new version to production
4. backup-restore.sh       ← Run manually to create or restore backups
```

All scripts are wired to Makefile targets — you rarely need to call them directly.

---

### `setup-minikube.sh`

Creates the local Kubernetes cluster, enables required addons, creates namespaces, and configures `/etc/hosts` with the cluster IP.

```bash
./scripts/setup-minikube.sh
# or
make cluster
```

Idempotent — if the cluster already exists it skips creation and updates `/etc/hosts` with the current IP. Validates Minikube ≥ v1.31 before starting.

Cluster spec: Kubernetes v1.28.0, 6 CPUs, 8 GB RAM, 60 GB disk. Addons: `ingress`, `metrics-server`, `storage-provisioner`.

---

### `install-argocd.sh`

Installs ArgoCD via Helm, waits for it to be ready, then bootstraps the App of Apps pattern.

```bash
./scripts/install-argocd.sh
# or
make argocd
```

What happens:
1. Validates Helm ≥ v3.8
2. Adds the ArgoCD Helm repo and installs/upgrades to chart version 7.7.0 with values from `k8s/helm/values/argocd.yaml`
3. Waits for `argocd-initial-admin-secret` to be available
4. Applies the AppProject (`k8s/argocd/projects/`)
5. Applies the bootstrap Application (`k8s/argocd/bootstrap-app.yaml`)
6. Prints the access URL, username, and initial password

After this, run `make argocd-apps` to apply all ArgoCD Application definitions (ArgoCD then auto-syncs everything in `k8s/argocd/applications/`).

---

### `blue-green-switch.sh`

Switches live traffic between the blue and green deployments of the API.

```bash
./scripts/blue-green-switch.sh
# or
make blue-green
```

The script detects the currently active slot, scales up the inactive one, runs a health check on every pod, asks for confirmation, then patches the service selector. If any pod is unhealthy it rolls back the scale and exits. The old slot is kept running for instant rollback.

---

### `backup-restore.sh`

```bash
# Create a full Velero backup of the openpanel namespace
./scripts/backup-restore.sh backup
# or
make backup-run

# Back up databases individually (PostgreSQL, Redis, ClickHouse)
./scripts/backup-restore.sh backup-db

# List available backups
./scripts/backup-restore.sh list

# Restore from a specific backup
./scripts/backup-restore.sh restore manual-backup-20241107-143000
```

---

## Starting from scratch

Use these steps whenever you want to tear everything down and start clean.

### Option A — Full cleanup with Make (recommended)

```bash
# Stop + delete cluster, remove /etc/hosts entries, remove credentials and Helm repos
make clean-all

# Or just remove the cluster and DNS (keep credentials and Helm repos)
make clean
```

`make clean` does three things in order:
1. `minikube stop -p openpanel` — graceful shutdown
2. `minikube delete -p openpanel` — deletes the VM and all cluster data
3. `sudo sed -i '/openpanel\.local/d' /etc/hosts` — removes the DNS entries

`make clean-all` additionally:
4. Removes the `credentials-velero` file
5. Removes the `argo` and `sealed-secrets` Helm repos

### Option B — Manual teardown

```bash
# 1. Stop the cluster gracefully (optional — delete works even if running)
minikube stop -p openpanel

# 2. Delete the cluster and all its data
minikube delete -p openpanel

# 3. Remove DNS entries from /etc/hosts
sudo sed -i '/openpanel\.local/d' /etc/hosts

# 4. Verify the entry is gone
grep openpanel.local /etc/hosts || echo "DNS entries removed"

# 5. (Optional) Remove Helm repos added by this project
helm repo remove argo
helm repo remove sealed-secrets
helm repo remove prometheus-community
```

### Re-deploying from scratch

After cleanup, run the full setup again:

```bash
# One command — runs all steps in the correct order
make all GITHUB_USER=<your-user> GITHUB_TOKEN=<your-token>
```

> Remember to pre-install kube-prometheus-stack CRDs manually (Step 4 above) — this is not part of `make all`.

### Verify the cluster is gone

```bash
minikube status -p openpanel
# Expected: "Profile 'openpanel' not found"

kubectl config get-contexts | grep openpanel
# Expected: no output
```

---

## Testing the CI pipeline locally with `act`

`act` runs GitHub Actions workflows on your local machine using Docker. This lets you catch errors before pushing.

### Install act

```bash
curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | bash
```

### Create the secrets file

```bash
# .secrets — already in .gitignore, never commit this
echo "GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx" > .secrets
```

### Workflows in this repository

| File | Trigger | What it does |
|---|---|---|
| `ci-validate.yml` | Push/PR to master | Lint app, validate K8s manifests, scan secrets |
| `ci-build-publish.yml` | After ci-validate passes | Build + push Docker images to GHCR, Trivy scan, SBOM |
| `cd-update-tags.yml` | After ci-build-publish passes | Update image tags in k8s manifests, commit + push, create git tag |

### Run the full CI pipeline

```bash
# Run the complete CI-Lint-Validate workflow
act push --workflows .github/workflows/ci-validate.yml --secret-file .secrets

# Run only the lint-and-test job
act push --workflows .github/workflows/ci-validate.yml --job lint-and-test --secret-file .secrets

# Run only the validate-infra job
act push --workflows .github/workflows/ci-validate.yml --job validate-infra --secret-file .secrets

# Run only the secret-scan job
act push --workflows .github/workflows/ci-validate.yml --job secret-scan --secret-file .secrets
```

> On first run `act` downloads a base image (~500 MB). Use `-P ubuntu-latest=catthehacker/ubuntu:act-latest` if the default image is missing tools.

---

## Testing individual checks without act

Run each CI check directly from your terminal. These are the exact same commands the pipeline runs.

### Validate Kubernetes manifests

```bash
# 1. Build the overlay to a single file
kustomize build k8s/overlays/local > /tmp/rendered-manifests.yaml

# 2. Validate schemas against Kubernetes 1.28
kubeconform \
  -summary \
  -strict \
  -ignore-missing-schemas \
  -kubernetes-version 1.28.0 \
  /tmp/rendered-manifests.yaml

# 3. Check best practices
kube-linter lint /tmp/rendered-manifests.yaml --config .kube-linter.yaml

# 4. Lint all Dockerfiles (failure-threshold error means warnings are allowed)
hadolint --failure-threshold error openpanel/apps/api/Dockerfile
hadolint --failure-threshold error openpanel/apps/start/Dockerfile
hadolint --failure-threshold error openpanel/apps/worker/Dockerfile
```

### Scan for secrets

```bash
# Scan the full repository history
gitleaks detect --source . --verbose
```

### Scan a container image for vulnerabilities

```bash
# Build the image first
docker build -t openpanel-api:local ./openpanel -f ./openpanel/apps/api/Dockerfile

# Scan it — reports CRITICAL and HIGH, fails if patchable vulns found
trivy image \
  --severity CRITICAL,HIGH \
  --exit-code 1 \
  --ignore-unfixed \
  openpanel-api:local
```

### Generate an SBOM locally

```bash
# Install syft (the tool behind anchore/sbom-action)
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

# Generate SBOM for a local image
syft openpanel-api:local -o spdx-json > sbom-api.spdx.json

# Inspect it
cat sbom-api.spdx.json | jq '.packages | length'
```

---

## Testing AlertManager locally without Slack

AlertManager can be tested end-to-end using a local webhook receiver. No Slack account needed.

### Step 1 — Start a local webhook listener

```bash
docker run -d --name webhook-test -p 9095:9095 \
  docker.io/prom/alertmanager-webhook-logger:latest
```

### Step 2 — Update AlertManager to send to the local webhook

Edit `k8s/helm/values/kube-prometheus-stack.yaml`, replace the `null` receiver:

```yaml
receivers:
  - name: 'null'
    webhook_configs:
      - url: 'http://host.minikube.internal:9095'
        send_resolved: true
```

> `host.minikube.internal` routes from inside the cluster to your machine's port 9095.

### Step 3 — Trigger an alert manually

```bash
kubectl port-forward -n observability svc/alertmanager-operated 9093:9093 &

curl -XPOST http://localhost:9093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "critical",
      "namespace": "openpanel"
    },
    "annotations": {
      "summary": "Manual test alert",
      "description": "This is a test"
    },
    "generatorURL": "http://localhost:9090"
  }]'
```

### Step 4 — Verify the alert was received

```bash
docker logs webhook-test
# Expected: JSON payload containing "TestAlert"
```

---

## Testing the full GitOps flow locally

```bash
# 1. Make a code change in openpanel/

# 2. Build and push the image to GHCR
docker build -t ghcr.io/<your-user>/openpanel-api:main-local \
  ./openpanel -f ./openpanel/apps/api/Dockerfile
docker push ghcr.io/<your-user>/openpanel-api:main-local

# 3. Manually update the image tag (what the CD pipeline does automatically)
sed -i "s|image: ghcr.io/.*/openpanel-api:.*|image: ghcr.io/<your-user>/openpanel-api:main-local|g" \
  k8s/base/openpanel/api-deployment-blue.yaml

# 4. Commit and push — ArgoCD detects the change and deploys
git add k8s/base/openpanel/api-deployment-blue.yaml
git commit -m "chore: test local image update"
git push

# 5. Watch ArgoCD sync
argocd app sync openpanel --grpc-web
argocd app wait openpanel --health --grpc-web
```

---

## Testing the blue-green switch locally

```bash
# Verify both deployments exist
kubectl get deployments -n openpanel | grep api
# Expected: openpanel-api-blue and openpanel-api-green

# Check current active version
kubectl get svc openpanel-api -n openpanel -o jsonpath='{.spec.selector.version}'
# Expected: "blue" or "green"

# Run the switch script
./scripts/blue-green-switch.sh
# or
make blue-green

# Verify traffic switched
kubectl get svc openpanel-api -n openpanel -o jsonpath='{.spec.selector}'
# Expected: version changed from the previous value
```

---

## Testing backup and restore locally

```bash
# Verify Velero is running
kubectl get pods -n velero
# Expected: velero pod Running

# Verify MinIO is running (the backup storage)
kubectl get pods -n backup
# Expected: minio pod Running

# Create a test backup
./scripts/backup-restore.sh backup
# or
make backup-run

# List it
./scripts/backup-restore.sh list

# Simulate a disaster — delete a deployment
kubectl delete deployment openpanel-api-blue -n openpanel

# Restore from the backup
./scripts/backup-restore.sh restore <backup-name-from-list>

# Verify it came back
kubectl get deployment openpanel-api-blue -n openpanel
# Expected: deployment recreated with desired replica count
```

---

## Quick sanity check before any push

Run this sequence from the repo root before every `git push`:

```bash
# 1. Build and validate manifests
kustomize build k8s/overlays/local | \
  kubeconform -summary -strict -ignore-missing-schemas -kubernetes-version 1.28.0 -

# 2. Lint manifests for best practices
kustomize build k8s/overlays/local > /tmp/manifests.yaml && \
  kube-linter lint /tmp/manifests.yaml

# 3. Lint Dockerfiles
hadolint --failure-threshold error openpanel/apps/api/Dockerfile
hadolint --failure-threshold error openpanel/apps/start/Dockerfile
hadolint --failure-threshold error openpanel/apps/worker/Dockerfile

# 4. Scan for secrets
gitleaks detect --source . --verbose
```

> Note: `pnpm lint`, `pnpm typecheck`, and `pnpm test` are intentionally not part of the CI pipeline for this DevOps project. The pipeline focuses on infrastructure validation, image building, and deployment — not app-level testing.
