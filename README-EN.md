# OpenPanel DevOps Project

Complete DevOps pipeline for [OpenPanel](https://github.com/Openpanel-dev/openpanel) deployed on Kubernetes with GitOps, full observability, Blue-Green deployment and automated backup.

**Author:** Rubén López Solé

**Specialization:** GitOps with ArgoCD

**Master in DevOps & Cloud Computing — March 2026**

---

## Stack

| Area | Tool |
|---|---|
| Orchestration | Kubernetes (Minikube) |
| GitOps / CD | ArgoCD |
| CI | GitHub Actions |
| Registry | GitHub Container Registry (GHCR) |
| Secrets | Sealed Secrets (Bitnami) |
| Metrics | Prometheus + AlertManager |
| Logs | Loki + Promtail |
| Traces | Tempo |
| Dashboards | Grafana |
| Supply Chain | SBOM (Anchore) + Trivy |
| Backup | Velero + MinIO |
| IaC | Terraform + LocalStack |
| Deployment | Blue-Green (API) |

---

## Automatic Deployment

To deploy the entire project from scratch with a single command:

```bash
make all GITHUB_USER=rubenlopsol GITHUB_TOKEN=gho_xxx
```

ArgoCD will automatically synchronize the application, observability and backup after installation. To see all available commands:

```bash
make help
```

---

## Repository Structure

```
proyecto_final/
├── .github/workflows/
│   ├── ci-validate.yml          # CI-Lint-Test-Validate: validates K8s manifests, Dockerfiles, and secrets on every PR/push
│   ├── ci-build-publish.yml     # CI-Build-Publish: builds images, generates SBOM, scans with Trivy
│   └── cd-update-tags.yml       # CD-Update-GitOps-Manifests: updates image tags and creates release tag
│
├── .kube-linter.yaml            # kube-linter checks configuration (enabled and excluded checks)
├── .hadolint.yaml               # hadolint configuration (minimum failure severity)
│
├── openpanel/                   # OpenPanel source code (fork)
│
├── k8s/
│   ├── base/
│   │   ├── namespaces/          # Namespace definitions
│   │   ├── openpanel/           # API (blue/green), Dashboard, Worker, PostgreSQL, ClickHouse, Redis
│   │   └── backup/              # MinIO, Velero schedules
│   ├── helm/
│   │   └── values/              # Values files for Helm charts
│   │       ├── kube-prometheus-stack.yaml  # Prometheus + Grafana + AlertManager + alerts
│   │       ├── argocd.yaml                 # ArgoCD Helm values
│   │       ├── loki.yaml                   # Log aggregation
│   │       ├── promtail.yaml               # Log collection
│   │       └── tempo.yaml                  # Distributed tracing
│   ├── overlays/
│   │   └── local/               # Overlay for Minikube (resource limits)
│   └── argocd/
│       ├── bootstrap-app.yaml   # App of Apps — GitOps bootstrap root
│       ├── applications/        # ArgoCD Application manifests (Kustomize + Helm)
│       ├── projects/            # ArgoCD AppProject (permissions and scope)
│       └── sealed-secrets/      # Encrypted secrets (Sealed Secrets)
│
├── scripts/
│   ├── setup-minikube.sh        # Starts the cluster, creates namespaces and configures /etc/hosts
│   ├── install-argocd.sh        # Installs ArgoCD via Helm and applies the App of Apps bootstrap
│   ├── blue-green-switch.sh     # Blue-Green switch with health checks and confirmation prompt
│   └── backup-restore.sh        # Backup and restore (Velero, PostgreSQL, Redis, ClickHouse)
│
├── terraform/
│   ├── main.tf                  # S3 bucket + configuration (real AWS)
│   ├── iam.tf                   # IAM Role + IRSA for EKS (real AWS)
│   ├── variables.tf
│   ├── outputs.tf
│   └── localstack/              # LocalStack version for local validation
│       ├── main.tf
│       ├── iam.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── credentials-velero.example   # MinIO credentials template for Velero
├── Makefile                     # Full deployment automation
│
└── docs/
    ├── documentacion/           # Complete technical documentation (ES)
    └── propuesta_proyecto/      # Project proposal
```

---

## Quick Start

### Requirements

| Tool | Minimum version | Purpose |
|---|---|---|
| Docker | any | Minikube driver |
| Minikube | v1.31 | Local Kubernetes cluster (required for K8s v1.28) |
| kubectl | v1.28 | Kubernetes CLI |
| Helm | v3.8 | Chart management (required for OCI and ArgoCD chart 7.7) |
| ArgoCD CLI | any | ArgoCD application management |
| kubeseal | any | Sealed Secrets encryption |
| velero CLI | any | Backup operations |

> `setup-minikube.sh` and `install-argocd.sh` verify the Minikube and Helm versions automatically and fail with a clear message if requirements are not met.

---

### 1. Start the cluster and configure DNS

```bash
./scripts/setup-minikube.sh
```

The script is idempotent — if the cluster already exists, it skips creation. On completion it automatically configures `/etc/hosts` with the cluster IP for all project domains.

---

### 2. Install Sealed Secrets

```bash
make sealed-secrets
```

Installs the Sealed Secrets controller and applies the encrypted secrets from the repository.

> The secrets in this repository are encrypted with the original cluster key. On a new cluster they must be recreated. See [Adapting the project](#adapting-the-project-for-a-new-environment).

---

### 3. Install ArgoCD and bootstrap

```bash
./scripts/install-argocd.sh
```

The script installs ArgoCD via Helm (`helm upgrade --install`), waits for the admin secret, applies the AppProject and applies the bootstrap Application (App of Apps). On completion it prints the access URL and initial credentials.

ArgoCD will automatically sync everything in `k8s/argocd/applications/` — the application, observability and backup.

```bash
# Watch apps syncing
kubectl get applications -n argocd -w
```

---

### 4. Install Velero

```bash
# Create the MinIO credentials file from the template
cp credentials-velero.example credentials-velero
# Edit credentials-velero with your real credentials (do not commit this file)

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000

kubectl apply -f k8s/base/backup/velero/schedule.yaml
```

---

### Accessing the services

| Service | URL |
|---|---|
| Dashboard | http://openpanel.local |
| API | http://api.openpanel.local |
| ArgoCD | http://argocd.local |
| Grafana | http://grafana.local |
| Prometheus | http://prometheus.local |

```bash
# Open all UIs at once
make open
```

---

## Cluster management commands

```bash
make status       # General status: cluster, namespaces, pods, ArgoCD apps
make stop         # Stop Minikube without deleting the cluster
make restart      # Stop and restart Minikube
make dns          # Refresh /etc/hosts (useful if Minikube gets a new IP after restart)
make logs         # Live logs from the API pods
make blue-green   # Run the Blue-Green switch for the API
make backup-run   # Create a manual Velero backup
make open         # Open all UIs in the browser
```

---

## Clean up and start from scratch

```bash
# Stop and delete the cluster + clean /etc/hosts
make clean

# clean + remove credentials-velero and Helm repos
make clean-all
```

To redeploy after cleaning:

```bash
make all GITHUB_USER=<user> GITHUB_TOKEN=<token>
```

---

## CI/CD Pipeline

The pipeline is split into three chained workflows:

```
push / PR
    │
    ▼
ci-validate.yml          ← K8s manifest validation, Dockerfile linting, secret scanning
    │ (master only)
    ▼
ci-build-publish.yml     ← Docker image build, SBOM generation, Trivy scan
    │
    ▼
cd-update-tags.yml       ← updates image tags in Git, creates release/main-<sha> tag
    │
    ▼
ArgoCD detects the commit and deploys automatically
```

- Pull Requests only run `ci-validate.yml` — they never publish images.
- `ci-validate.yml` runs three infrastructure checks:
  - **kubeconform** — validates K8s manifests (strict mode, K8s 1.28 schema, verbose per-resource output)
  - **kube-linter** — security best-practices on manifests (configured in `.kube-linter.yaml`)
  - **hadolint** — Dockerfile linting (only fails on errors; upstream code warnings are suppressed via `.hadolint.yaml`)
  - **Gitleaks** — detects accidentally committed secrets
- App lint and tests are **intentionally disabled** — this DevOps project does not own the OpenPanel source code. See comment in `ci-validate.yml`.
- An SBOM (Software Bill of Materials) is generated in SPDX-JSON format for each published image.
- Trivy fails the pipeline if `CRITICAL` or `HIGH` vulnerabilities with an available patch are found.
- The CD sets `targetRevision` to the immutable `release/main-<sha>` tag — every deployment is reproducible and instantly rollback-able.

---

## Adapting the Project for a New Environment

### 1. GitHub user and repository

```bash
# Replace the username across the entire k8s/ directory
find k8s/ -name "*.yaml" -exec sed -i \
  's/RubenLopSol/<YOUR_GITHUB_USERNAME>/g; s/rubenlopsol/<your_username_lowercase>/g' {} +
```

Affected files: ArgoCD Applications (repoURL), AppProject (sourceRepos) and Deployments (GHCR image).

You also need to create the `REGISTRY_OWNER` Actions variable in your GitHub repository (the CI/CD pipeline uses it to build and push images to GHCR):

```bash
gh variable set REGISTRY_OWNER \
  --repo <YOUR_USERNAME>/<REPO> \
  --body "<your_username_lowercase>"
```

> `make setup-github` does this automatically when creating the repository.

---

### 2. Sealed Secrets — Recreate on the new cluster

Sealed Secrets are encrypted with the original cluster's key and cannot be decrypted on any other cluster. They must be recreated with `kubeseal` pointing at the new cluster.

| Secret | Namespace | Required keys |
|---|---|---|
| `postgres-credentials` | `openpanel` | `postgres-user`, `postgres-password` |
| `redis-credentials` | `openpanel` | `redis-password` |
| `clickhouse-credentials` | `openpanel` | `clickhouse-user`, `clickhouse-password` |
| `openpanel-secrets` | `openpanel` | `secret` (JWT secret) |
| `grafana-admin-credentials` | `observability` | `admin-user`, `admin-password` |

```bash
kubectl create secret generic postgres-credentials \
  --from-literal=postgres-user=postgres \
  --from-literal=postgres-password=YOUR_SECURE_PASSWORD \
  --namespace openpanel \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --format yaml \
  > k8s/argocd/sealed-secrets/postgres-credentials.yaml
```

---

### 3. Application ConfigMap

Update the URLs in `k8s/base/openpanel/configmap.yaml` if you use a different domain than `openpanel.local`:

```yaml
data:
  NEXT_PUBLIC_API_URL: "http://api.YOUR_DOMAIN"
  NEXT_PUBLIC_DASHBOARD_URL: "http://YOUR_DOMAIN"
```

---

### 4. Velero / MinIO Credentials

```ini
# credentials-velero  (do not commit)
[default]
aws_access_key_id=YOUR_MINIO_ACCESS_KEY
aws_secret_access_key=YOUR_MINIO_SECRET_KEY
```

---

### Adaptation checklist

- [ ] Replace `RubenLopSol` / `rubenlopsol` with your GitHub username
- [ ] Recreate all Sealed Secrets with your new cluster key
- [ ] Update URLs in `configmap.yaml` if you use a different domain
- [ ] Create the `credentials-velero` file with your MinIO credentials
- [ ] Fork the repository and update ArgoCD `repoURL` values to your fork

---

## Documentation

The complete technical documentation is in [`docs/documentacion/`](docs/documentacion/) in both Spanish and English:

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](docs/documentacion/ARCHITECTURE.md) | System architecture, diagrams, namespaces |
| [SETUP.md](docs/documentacion/SETUP.md) | Step-by-step installation of the complete environment |
| [GITOPS.md](docs/documentacion/GITOPS.md) | GitOps flow, ArgoCD, App of Apps, Kustomize |
| [CICD.md](docs/documentacion/CICD.md) | CI/CD pipeline, jobs, SBOM, tag strategy |
| [BLUE-GREEN.md](docs/documentacion/BLUE-GREEN.md) | Blue-Green strategy for the API |
| [OBSERVABILITY.md](docs/documentacion/OBSERVABILITY.md) | Prometheus, AlertManager, Grafana, Loki, Tempo |
| [BACKUP-RECOVERY.md](docs/documentacion/BACKUP-RECOVERY.md) | Velero + MinIO, schedules, restore |
| [SECURITY.md](docs/documentacion/SECURITY.md) | Sealed Secrets, Network Policies, RBAC |
| [OPERATIONS.md](docs/documentacion/OPERATIONS.md) | System operation commands |
| [RUNBOOK.md](docs/documentacion/RUNBOOK.md) | Procedures for deployments and incidents |
| [TERRAFORM.md](docs/documentacion/TERRAFORM.md) | Terraform for S3+IAM on AWS; local validation with LocalStack |
