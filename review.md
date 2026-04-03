# Final Repository Structure

```
k8s/
├── apps/                                       ← Layer 2: application workloads
│   ├── base/
│   │   └── openpanel/                          ← base manifests (common to all envs)
│   │       ├── api-deployment-blue.yaml        ← replicas: 2, live traffic
│   │       ├── api-deployment-green.yaml       ← replicas: 0, rollback target
│   │       ├── api-service.yaml                ← port 3333→3000, selector: version: blue
│   │       ├── start-deployment.yaml
│   │       ├── start-service.yaml
│   │       ├── worker-deployment.yaml
│   │       ├── postgres-statefulset.yaml
│   │       ├── postgres-service.yaml
│   │       ├── clickhouse-statefulset.yaml
│   │       ├── clickhouse-service.yaml
│   │       ├── clickhouse-configmap.yaml
│   │       ├── redis-deployment.yaml
│   │       ├── redis-service.yaml
│   │       ├── migrate-job.yaml                ← ArgoCD PreSync hook (prisma migrate deploy)
│   │       ├── network-policies.yaml           ← default-deny-all + explicit allow rules
│   │       ├── ingress.yaml
│   │       ├── configmap.yaml
│   │       └── kustomization.yaml
│   └── overlays/
│       ├── staging/                            ← Minikube: 1 replica, reduced resources
│       │   ├── kustomization.yaml
│       │   └── patches/
│       │       ├── api-blue.yaml               ← replicas: 1, cpu: 100m, mem: 256Mi
│       │       ├── start.yaml                  ← reduced resources
│       │       └── worker.yaml                 ← reduced resources
│       └── prod/                               ← production: higher replicas, TLS, PDB
│           ├── kustomization.yaml
│           ├── patches/
│           │   ├── api-blue.yaml               ← replicas: 3
│           │   ├── worker.yaml                 ← replicas: 2
│           │   ├── ingress.yaml                ← TLS + cert-manager + real domains
│           │   └── configmap.yaml              ← production URLs
│           └── resources/
│               └── pdb.yaml                    ← PodDisruptionBudget (minAvailable: 1)
│
└── infrastructure/                             ← Layer 1: cluster platform (deployed first)
    ├── base/
    │   ├── namespaces/                         ← namespace definitions (all envs)
    │   │   ├── namespaces.yaml
    │   │   └── kustomization.yaml
    │   ├── observability/                      ← base Helm values (common to all envs)
    │   │   ├── kube-prometheus-stack.yaml      ← Prometheus + Grafana + AlertManager
    │   │   ├── loki.yaml                       ← log aggregation
    │   │   ├── promtail.yaml                   ← log collection (DaemonSet)
    │   │   └── tempo.yaml                      ← distributed tracing
    │   ├── backup/                             ← MinIO + Velero daily schedule (base)
    │   └── sealed-secrets/                     ← kubeseal encrypted secrets (manual apply)
    │       ├── minio/
    │       │   ├── deployment.yaml
    │       │   ├── service.yaml
    │       │   └── pvc.yaml                    ← 10Gi base size (patched per overlay)
    │       ├── velero/
    │       │   ├── schedule.yaml               ← daily-full-backup only
    │       │   └── backup-location.yaml
    │       └── kustomization.yaml
    ├── overlays/
    │   ├── staging/                            ← Minikube overrides
    │   │   ├── kustomization.yaml              ← minio PVC → 5Gi
    │   │   ├── patches/
    │   │   │   └── minio-pvc.yaml
    │   │   └── values/                         ← Helm overrides (ArgoCD multi-source)
    │   │       ├── kube-prometheus-stack.yaml  ← 3d retention, 5Gi storage
    │   │       └── loki.yaml                   ← minimal resources
    │   └── prod/                               ← production overrides
    │       ├── kustomization.yaml              ← minio PVC → 50Gi + hourly schedule
    │       ├── patches/
    │       │   └── minio-pvc.yaml
    │       ├── resources/
    │       │   └── velero-schedule-hourly.yaml ← prod-only hourly DB backup
    │       └── values/                         ← Helm overrides (ArgoCD multi-source)
    │           ├── kube-prometheus-stack.yaml  ← 30d retention, 50Gi, 2 replicas
    │           └── loki.yaml                   ← 2 replicas
    └── argocd/
        ├── argocd.yaml                         ← ArgoCD Helm values
        ├── bootstrap-app.yaml                  ← App of Apps root (one manual apply)
        ├── applications/                       ← ArgoCD Application CRs
        │   ├── namespaces-app.yaml             ← deploys base/namespaces
        │   ├── backup-app.yaml                 ← deploys overlays/staging
        │   ├── observability-prometheus-app.yaml ← Helm + base + staging values
        │   ├── observability-loki-app.yaml
        │   ├── observability-promtail-app.yaml
        │   ├── observability-tempo-app.yaml
        │   └── openpanel-app.yaml              ← deploys apps/overlays/staging
        └── projects/
            └── openpanel-project.yaml
```

---

# Project Data Flow — Build From Scratch

```
DAY 0 — CLUSTER BOOTSTRAP
  scripts/setup-minikube.sh       ← spin up Minikube
  make terraform-infra ENV=staging     ← provision S3 + IAM (terraform/environments/staging)
  scripts/install-argocd.sh       ← install ArgoCD + apply bootstrap-app.yaml
        ↓
GITOPS LAYER
  k8s/infrastructure/argocd/bootstrap-app.yaml   ← App of Apps root, watches master
  k8s/infrastructure/argocd/projects/            ← AppProject (RBAC scope)
  k8s/infrastructure/argocd/applications/        ← one Application per component
        ↓
SECRETS LAYER (manual, before sync)
  k8s/infrastructure/base/sealed-secrets/      ← kubeseal encrypted secrets
        ↓
APP LAYER (ArgoCD syncs k8s/apps/overlays/staging)
  k8s/infrastructure/base/namespaces/        ← namespace definitions
  k8s/apps/base/openpanel/                   ← api, start, worker, postgres, redis, clickhouse
  k8s/infrastructure/base/observability/     ← observability (prometheus, loki, tempo, promtail)
  k8s/infrastructure/overlays/staging/       ← MinIO (5Gi) + Velero daily schedule
        ↓
RUNTIME OPERATIONS
  scripts/blue-green-switch.sh    ← traffic cut-over
  scripts/backup-restore.sh       ← Velero restore procedure
        ↓
CI/CD LOOP (ongoing)
  .github/workflows/              ← already reviewed ✓
```

---

# Cluster Bootstrap Order

Full sequence from zero to a running cluster. Only steps 1, 2, 3 and 6 require manual commands — everything else is scripted or driven by ArgoCD watching Git.

## Step 0 — Provision infrastructure with Terraform (run once, before cluster)

```bash
# Start LocalStack (emulates AWS S3 + Secrets Manager + IAM locally)
docker run -d -p 4566:4566 localstack/localstack

# Provision and write credentials-velero in one command
make terraform-infra ENV=staging
```

`make terraform-infra` runs `terraform init && terraform apply` inside `terraform/environments/staging/`, then writes the generated IAM credentials directly to `credentials-velero`.

Creates in LocalStack:
- **S3 bucket** (`openpanel-velero-backups`) — Velero backup target. Versioning on, AES-256 encryption, public access blocked, 30-day lifecycle.
- **Secrets Manager slot** (`devops-cluster/sealed-secrets-master-key`) — empty slot populated later by `make backup-sealing-key`.
- **IAM user** (`velero-backup-user`) + access key — scoped to S3 put/get/delete/list on the bucket only. Written to `credentials-velero`.

> Terraform only provisions the infrastructure slots. The actual key and backup data are written later by `make backup-sealing-key` and Velero respectively.

See `terraform/README.md` for the full module breakdown and end-to-end connection diagram.

## Step 1 — `./scripts/setup-minikube.sh` (scripted)

Validates prerequisites (minikube ≥ v1.31, kubectl, docker), then starts a 3-node `devops-cluster` profile on Kubernetes v1.28 using the Docker driver. Each node gets 4 CPUs / 4Gi RAM (12 CPUs / 12Gi total). Addons: `ingress`, `metrics-server`, `storage-provisioner`.

Waits for all 3 nodes to be `Ready`, then labels the two workers:

```
devops-cluster-m02   →  workload=app            (OpenPanel API, Worker, databases)
devops-cluster-m03   →  workload=observability  (Prometheus, Grafana, Loki, Tempo)
```

Updates `/etc/hosts` with the Minikube IP so all `.local` domains resolve locally.

## Step 2 — `make sealed-secrets ENV=staging` (must come before ArgoCD)

```bash
make sealed-secrets ENV=staging
```

Installs the Sealed Secrets controller via `kustomize build --enable-helm`, waits for it to be ready, then seals all 6 credentials with the cluster's RSA public key and applies them. The controller decrypts them and creates the real Kubernetes Secrets in their namespaces.

Must run **before** ArgoCD because ArgoCD syncs openpanel immediately, and those pods need the Secrets to already exist.

| Secret | Namespace |
|---|---|
| `postgres-credentials` | `openpanel` |
| `redis-credentials` | `openpanel` |
| `clickhouse-credentials` | `openpanel` |
| `openpanel-secrets` | `openpanel` |
| `grafana-admin-credentials` | `observability` |
| `minio-credentials` | `backup` |

> Re-running `make sealed-secrets` on an existing cluster is safe — it skips the reseal step if `secrets.yaml` already exists.

## Step 3 — `make backup-sealing-key` (run immediately after step 2)

```bash
make backup-sealing-key
```

Exports the controller's RSA TLS secret from the cluster and stores it in LocalStack Secrets Manager under `devops-cluster/sealed-secrets-master-key`. Without this backup, destroying the cluster makes all existing SealedSecrets permanently unreadable.

## Step 4 — `./scripts/install-argocd.sh` (scripted)

- Installs/upgrades ArgoCD via Helm (values from `k8s/infrastructure/argocd/argocd.yaml`)
- Waits for the admin secret, prints login credentials
- Applies the AppProject — defines which namespaces and API groups each app can touch
- Applies `bootstrap-app.yaml` — the single one-time trigger that starts the App of Apps pattern

## Step 5 — ArgoCD auto-reconciles all apps (zero manual steps)

The bootstrap app watches `k8s/infrastructure/argocd/applications/` on master and creates all Application CRs automatically:

| ArgoCD App | What it deploys | Method |
|---|---|---|
| `namespaces` | All cluster namespaces | Kustomize — `k8s/infrastructure/base/namespaces` |
| `openpanel` | API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis, Ingress | Kustomize — `k8s/apps/overlays/staging` |
| `observability` | Prometheus, Grafana, Loki, Promtail, Tempo | Kustomize + Helm (`--enable-helm`) — `overlays/staging/observability` |
| `minio` | MinIO Deployment + PVC (5Gi staging) | Kustomize — `overlays/staging/minio` |
| `velero` | BackupStorageLocation + daily Schedule | Kustomize — `overlays/staging/velero` |
| `sealed-secrets` | Controller (already running) + SealedSecrets file | Kustomize + Helm (`--enable-helm`) — `overlays/staging/sealed-secrets` |

## Step 6 — Install Velero server (manual, after MinIO is up)

Velero's server (the controller pod) must be installed via CLI — it cannot be bootstrapped by ArgoCD because it needs to already be running before its own CRDs (BackupStorageLocation, Schedule) are applied. Wait for the `minio` ArgoCD app to be Healthy first.

```bash
cat > velero-credentials <<EOF
[default]
aws_access_key_id=<MINIO_USER from .secrets>
aws_secret_access_key=<MINIO_PASSWORD from .secrets>
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --namespace velero \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000

rm velero-credentials
```

ArgoCD's `velero` app (already synced in step 5) has applied the BackupStorageLocation and Schedule — Velero finds them in the `velero` namespace immediately.

## Full flow summary

```
terraform apply (localstack/)        ← S3 bucket + Secrets Manager slot
        ↓
./scripts/setup-minikube.sh          ← 3-node cluster + node labels + /etc/hosts
        ↓
make sealed-secrets ENV=staging      ← controller + seal + apply all 6 secrets
        ↓
make backup-sealing-key              ← RSA key → LocalStack Secrets Manager
        ↓
./scripts/install-argocd.sh          ← ArgoCD + AppProject + bootstrap-app
        ↓
ArgoCD reconciles automatically:
  namespaces → openpanel → observability → minio → velero → sealed-secrets
        ↓
velero install --namespace velero    ← Velero server (manual, needs MinIO up)
        ↓
Git commits drive all deployments from here
```

---

## Review Checklist

| # | Area | Files | Status |
|---|------|-------|--------|
| 1 | GitHub Actions — CI validate | `.github/workflows/ci-validate.yml` | Reviewed ✓ |
| 2 | GitHub Actions — CI build/publish | `.github/workflows/ci-build-publish.yml` | Reviewed ✓ |
| 3 | GitHub Actions — CD update tags | `.github/workflows/cd-update-tags.yml` | Reviewed ✓ |
| 4 | Dependabot | `.github/dependabot.yml` | Reviewed ✓ |
| 5 | Cluster bootstrap scripts | `scripts/setup-minikube.sh`, `scripts/install-argocd.sh` | Reviewed ✓ |
| 6 | Terraform | `terraform/modules/`, `terraform/environments/` | Reviewed ✓ |
| 7 | Kustomize manifests — app layer | `k8s/apps/base/openpanel/`, `k8s/apps/overlays/staging/` | Reviewed ✓ |
| 8 | ArgoCD / GitOps config | `k8s/infrastructure/argocd/` | Pending |
| 9 | Sealed Secrets | `k8s/infrastructure/base/sealed-secrets/` | Pending |
| 10 | Observability | `k8s/infrastructure/base/observability/`, `k8s/infrastructure/overlays/*/values/` | Pending |
| 11 | Backup | `k8s/infrastructure/base/backup/`, `k8s/infrastructure/overlays/`, `scripts/backup-restore.sh` | Pending |
| 12 | Blue-Green | `scripts/blue-green-switch.sh` | Pending |
| 13 | Makefile | `Makefile` | Pending |

---

# How ArgoCD Detects New Versions — GitOps Flow

## Layer 1 — Bootstrap app watches master

`openpanel-app.yaml` has:
```yaml
targetRevision: master
path: k8s/apps/overlays/staging
```
ArgoCD polls the repo on master every ~3 minutes (default). When it sees this file change, it updates the `openpanel` Application CR in the cluster.

## Layer 2 — The CD workflow updates targetRevision

The CD workflow does this:
```bash
RELEASE_TAG="release/main-abc1234"
sed -i "s|targetRevision:.*|targetRevision: ${RELEASE_TAG}|" \
  k8s/infrastructure/argocd/applications/openpanel-app.yaml
git commit && git push origin HEAD:master
```

So the flow is:

```
CI builds image → pushes main-abc1234 to GHCR
    ↓
CD workflow updates openpanel-app.yaml on master
  (targetRevision: master → targetRevision: release/main-abc1234)
    ↓
Bootstrap ArgoCD app detects master changed
    ↓
Applies the updated Application CR to the cluster
    ↓
ArgoCD now syncs openpanel from release/main-abc1234 tag
    ↓
That tag has the updated image references → Kubernetes rolls out new pods
```

**Key insight:** ArgoCD doesn't watch the image registry — it only watches Git. The trigger is the commit to master that changes `targetRevision`. That's the GitOps pattern: Git is the single source of truth, not the container registry.

## Where bootstrap-app.yaml is applied

Defined in `scripts/install-argocd.sh` line 146:
```bash
kubectl apply -f k8s/infrastructure/argocd/bootstrap-app.yaml
```

Run **once, manually** from your local machine during initial cluster setup:
```bash
./scripts/install-argocd.sh
```

That script does the full setup in order:
1. Installs ArgoCD via Helm into the cluster
2. Applies the AppProject (permission scope)
3. Applies `bootstrap-app.yaml` — the one-time trigger

After that single command, you never need to touch the cluster directly again. Everything from that point forward is driven by Git commits.

```
You (once, on day 0)
  ./scripts/install-argocd.sh   ← run from your laptop/terminal
        ↓
ArgoCD installed in cluster
        ↓
bootstrap-app.yaml applied to cluster
        ↓
From now on: Git commits drive everything automatically
```

---

# Project Review — OpenPanel DevOps Master Final Project

**Date:** 2026-04-02  
**Reviewer:** Claude Code audit  
**Branch:** test/ci-pipeline-validation

---

## Project Overview

OpenPanel deployed on Kubernetes (Minikube) using a full GitOps chain.

| Layer | Technology |
|-------|------------|
| GitOps | ArgoCD — App of Apps pattern |
| CI/CD | GitHub Actions — 3 workflows (validate → build/publish → update manifests) |
| Blue-Green | Manual switch script + Service selector patch |
| Observability | kube-prometheus-stack (Prometheus + Grafana + AlertManager) + Loki + Tempo + Promtail |
| Secrets | Sealed Secrets (kubeseal) |
| Backup | Velero + MinIO |
| IaC | Terraform (LocalStack simulation of AWS S3 + IAM) |

---

## A. GitHub Actions Workflows

### 1. `ci-validate.yml` — CI-Lint-Test-Validate

**What it does:** Gate 1. Runs on every push and PR to master/main. Two jobs run in parallel: `validate-infra` (renders Kustomize, validates schemas with kubeconform, lints with kube-linter, checks Dockerfiles with hadolint) and `secret-scan` (gitleaks on the full git history). Nothing gets built unless this passes.

**Working correctly:**
- `permissions: read-all` at top level — correct least-privilege default
- All tools pinned to specific versions
- kubectl has SHA256 checksum verification
- `paths-ignore` for docs/markdown avoids wasted CI runs
- `workflow_dispatch` for manual triggers
- Gitleaks with `fetch-depth: 0` — required to scan full history
- kube-linter config with documented exclusions

**Issues found:**

**[BEST-1 — Best Practice]** No `concurrency` group. Rapid pushes to master create overlapping CI runs that waste compute and can produce confusing interleaved output.
- **Fix applied:** Added `concurrency: group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true`

**[SEC-2 — Security]** Four of five tools downloaded without integrity verification. `kustomize`, `kubeconform`, `kube-linter`, and `hadolint` were downloaded via `curl | tar xz` with no checksum check. Only `kubectl` had any verification, but even that fetched the `.sha256` file from the same server as the binary — if the server is compromised, both are replaced together and verification passes anyway.
- **Fix applied:** Each tool now has its expected SHA256 hardcoded as an env var (`KUBECTL_SHA256`, `KUSTOMIZE_SHA256`, etc.) directly in the workflow file alongside its version. The binary is downloaded, then verified with `echo "$SHA256  filename" | sha256sum --check` against the hardcoded value — no remote checksum file is fetched. The expected hash lives in version-controlled code, independent of the download server. Any change requires a code-review PR, making tampering visible and auditable. All five SHA256 values were fetched from official release sources and verified at pin time.

**[BEST-2 — Best Practice]** `kubeconform` used `-ignore-missing-schemas` only, silently skipping all CRDs (SealedSecret, ArgoCD Application, Velero Schedule). No CRD schema source was configured.
- **Fix applied:** Added `-schema-location default` and `-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'` so known CRDs are validated against the community catalog. `-ignore-missing-schemas` is kept for CRDs not yet in the catalog.

**[BEST-8 — Best Practice]** No `timeout-minutes` on jobs. A hanging Docker build or network stall would consume CI minutes indefinitely.
- **Fix applied:** `timeout-minutes: 15` on `validate-infra`, `timeout-minutes: 10` on `secret-scan`.

**[EXTRA-1 — Dead code]** Workflow-level `env:` block declared `REGISTRY: ghcr.io` and `IMAGE_PREFIX:` — these belong to `ci-build-publish.yml` and are never referenced anywhere in this workflow. Dead variables in CI files are a maintenance hazard: engineers waste time tracing where they're used.
- **Fix applied:** Removed the unused `env:` block entirely.

**[EXTRA-2 — Permissions]** `secret-scan` job had no `permissions:` override. With `permissions: read-all` at the top level, gitleaks-action has read-only access to everything — it cannot post inline PR annotations pointing at the exact line where a secret was found. The scan still runs and the job still fails on findings, but developers get no in-PR feedback.
- **Fix applied:** Added `permissions: { contents: read, pull-requests: write }` to the `secret-scan` job so gitleaks can annotate PRs directly.

---

### 2. `ci-build-publish.yml` — CI-Build-Publish

**What it does:** Gate 2. Triggered via `workflow_run` only after CI-Lint-Test-Validate succeeds on master/main (never on PRs — images are only published from the main branch). Two jobs: `build-and-push` (matrix over api/start/worker, builds images, pushes to GHCR with a SHA-based tag, generates SBOM) and `security-scan` (Trivy CVE scanner, uploads SARIF to GitHub Security tab).

**Working correctly:**
- `permissions: read-all` at top — correct
- Triggered only on successful CI gate (`workflow_run.conclusion == 'success'`)
- SBOM generation with artifact upload
- Trivy with `exit-code: "1"` + `ignore-unfixed: true` — good security gate
- Docker layer caching via GHA cache
- SARIF upload with `if: always()` — results visible even when Trivy fails

**Issues found:**

**[BEST-1 — Best Practice]** No `concurrency` group. Two builds for two fast commits would race each other.
- **Fix applied:** Added `concurrency: group: ${{ github.workflow }}-${{ github.event.workflow_run.head_sha }}, cancel-in-progress: false`. Uses the commit SHA (not the branch ref) so each commit gets its own build group. `cancel-in-progress: false` queues rather than cancels — every commit must produce a published image.

**[BUG-4 — Bug]** SBOM was generated against `:latest` tag, not the SHA-based tag just built. If another build ran between push and SBOM scan, the SBOM would describe the wrong image.
- **Fix applied:** SBOM now uses `${{ steps.meta.outputs.version }}` which resolves to `main-<sha7>` — the exact tag produced by `docker/metadata-action` for the current build.

**[BUG-4 — Bug]** Trivy was scanning `:latest` instead of the specific SHA tag. Same race condition as SBOM.
- **Fix applied:** Added a `Resolve image tag` step that reconstructs `ghcr.io/<owner>/openpanel-<service>:main-<sha7>` using `github.event.workflow_run.head_sha` (same SHA the build job used). Trivy now scans the exact image that was just published.

**[BEST-7 — Best Practice]** No `fail-fast` configuration on the matrix. Default is `true`, meaning if the `api` build fails the `start` and `worker` builds are cancelled — you lose visibility into all failures.
- **Fix applied:** Added `fail-fast: false` to both `build-and-push` and `security-scan` matrices.

**[BEST-8 — Best Practice]** No `timeout-minutes`. A slow image push or Trivy scan could run for hours.
- **Fix applied:** `timeout-minutes: 30` on `build-and-push`, `timeout-minutes: 20` on `security-scan`.

**[INFO-4 — Informational]** SBOM is uploaded as a CI artifact but not cryptographically attested to the image. Consumers cannot verify the SBOM is authentic. Adding `actions/attest-build-provenance` would be a strong differentiator for the project presentation. Not fixed — documented as a future improvement.

---

### 3. `cd-update-tags.yml` — CD-Update-GitOps-Manifests

**What it does:** Gate 3. Triggered after CI-Build-Publish succeeds. Updates image tags in four K8s manifest files (`api-deployment-blue.yaml`, `start-deployment.yaml`, `worker-deployment.yaml`, `migrate-job.yaml`), commits and pushes to master, creates a `release/main-<sha>` tag. ArgoCD's bootstrap app picks up the updated `openpanel-app.yaml` from master and reconciles the openpanel Application to deploy from the release tag.

**Working correctly:**
- Triggered only on successful build gate
- `owner` lowercased before use (GHCR requires lowercase image names)
- `git diff --staged --quiet ||` guard prevents empty commits
- Release tag created after the manifest-update commit (tag points to the right commit)

**Issues found:**

**[SEC-1 — Security]** No `permissions: read-all` at top level. Both other workflows have it. Without it, all GitHub Actions default permissions apply — which for some repos includes write access to issues, deployments, and checks.
- **Fix applied:** Added `permissions: read-all` at top. The job retains `contents: write` to allow committing and pushing.

**[BUG-1 — Bug]** No `concurrency` group. Two close-together builds trigger two CD runs simultaneously. Both try to `git push` to master — the second is rejected with "non-fast-forward". No retry, no rebase.
- **Fix applied:** Added `concurrency: group: cd-gitops, cancel-in-progress: false`. All CD runs are serialised into a single queue. `cancel-in-progress: false` ensures every image tag update gets committed.

**[INFO-2 — Minor]** `git push` had no explicit branch specification. If `actions/checkout@v4` set up the branch tracking differently in a `workflow_run` context, the push would target the wrong branch or fail.
- **Fix applied:** Changed to `git push origin HEAD:master` — always explicit.

**[BUG-missing — Bug]** `migrate-job.yaml` was not updated by the CD. The PreSync migration job uses the same API image. With the old CD, the job would run the previous version's migrations against the database before the new API was deployed — breaking the version alignment guarantee.
- **Fix applied:** Added a `Update Migrate job image tag` step that updates `migrate-job.yaml` with the same `sed` pattern used for the API deployment.

**[BEST-8 — Best Practice]** No `timeout-minutes`.
- **Fix applied:** `timeout-minutes: 10`.

**[INFO-5 — Informational / By design]** Only `api-deployment-blue.yaml` is updated. Green keeps the previous image tag. This is intentional: green serves as the instant rollback path during a blue-green switch. If both were updated, rollback would require a fresh deploy rather than a service selector flip. Documented with a comment in the workflow header.

---

### 4. `.github/dependabot.yml`

**[BEST-8 — Best Practice / SEC-3 — Security]** No automated updates for GitHub Actions versions. Tags like `@v4` are mutable — a tag can be moved to a malicious commit silently. Without Dependabot, action versions go stale and security patches are never applied.

**Fix applied:** Created `.github/dependabot.yml` with **daily** GitHub Actions update schedule (`interval: "daily"`). Dependabot opens one PR per outdated action per day with changelogs for review. The file also documents the path to full SHA pinning (the gold standard) for future hardening.

---

### 5. CD infinite loop — `[skip ci]`

**[BUG-5 — Bug]** The CD workflow commits updated image tags to `k8s/` files on master and pushes. `ci-validate.yml`'s `paths-ignore` only excludes `**.md`, `docs/**`, and `.gitignore` — it does **not** exclude `k8s/`. So the bot's commit triggers `ci-validate` → `ci-build-publish` → `cd-update-tags` → another bot commit → infinite loop. This would exhaust GitHub Actions minutes and produce an ever-growing chain of `chore: update image tags to…` commits on master.

**Fix applied:** The commit message in `cd-update-tags.yml` now includes `[skip ci]`:
```
chore: update image tags to main-<sha> [skip ci]
```
GitHub Actions treats `[skip ci]` in a commit message as a signal to suppress all workflow triggers for that push. The bot commit never starts the next CI run.

**Without `[skip ci]` — infinite loop:**
```
Developer pushes code to master
        ↓
ci-validate runs (triggered by push to master)
        ↓
ci-build-publish runs (triggered by ci-validate success)
        ↓
cd-update-tags runs (triggered by ci-build-publish success)
  → commits "chore: update image tags to main-abc1234"
  → git push origin HEAD:master
        ↓
That push triggers ci-validate AGAIN
        ↓
ci-build-publish runs AGAIN
        ↓
cd-update-tags runs AGAIN → pushes again → triggers again → ...
```
Note: the `git diff --staged --quiet ||` guard does NOT stop this — the second run's `sed`
produces no diff so no commit is made, but the push from the first run already fired the
next ci-validate trigger before the second run even starts.

**With `[skip ci]` — chain stops cleanly:**
```
Developer pushes code to master
        ↓
ci-validate runs
        ↓
ci-build-publish runs
        ↓
cd-update-tags runs
  → commits "chore: update image tags to main-abc1234 [skip ci]"
  → git push origin HEAD:master
        ↓
GitHub reads "[skip ci]" before any workflow evaluation
→ suppresses ALL workflow triggers for that push event
        ↓
Chain stops. Done.
```
`[skip ci]` is a pre-filter at the push event level — not a workflow condition. No workflow
ever receives the event.

---

## B. Kubernetes Manifests

How Kustomize assembles the final manifest for CI and for the cluster:

```
k8s/infrastructure/base/namespaces/namespaces.yaml  ← namespaces (openpanel, observability, argocd, backup)
k8s/apps/base/openpanel/                            ← all app manifests (deployments, services, jobs, netpols)
        ↓ kustomize build
k8s/apps/overlays/staging/kustomization.yaml        ← patches base with staging-specific replicas/resources
        ↓ rendered by CI (kustomize build k8s/apps/overlays/staging)
/tmp/rendered-apps-staging.yaml                     ← what kubeconform + kube-linter validate
        ↓ ArgoCD syncs this same overlay
cluster                                             ← live state
```

---

### `api-deployment-blue.yaml` / `api-deployment-green.yaml`

**How it works:** Blue-green pattern. Blue has `replicas: 2` and is live. Green has `replicas: 0` and sits idle as the rollback target. The `openpanel-api` Service selects `version: blue`. When the blue-green switch runs it patches the selector to `version: green` — instant, zero-downtime traffic cut-over.

**Working correctly:**
- `runAsNonRoot: true`, `runAsUser: 1001`, `fsGroup: 1001`
- `readOnlyRootFilesystem: true` + `/tmp` emptyDir volume for Node.js temp files
- All capabilities dropped (`drop: [ALL]`), `allowPrivilegeEscalation: false`
- Liveness on `/healthz/live` + readiness on `/healthcheck`, both with sane thresholds
- All secrets injected from SealedSecrets — no plaintext in the manifest
- `HOME`, `COREPACK_HOME`, `XDG_CACHE_HOME` all redirected to `/tmp` so the read-only filesystem doesn't break Node tooling

**Issues found:**

**[INFO — Informational]** `readinessProbe` path is `/healthcheck` while liveness uses `/healthz/live` — inconsistent naming, but confirmed working in the live cluster.

**[INFO — Informational]** `prometheus.io/scrape: "false"` — the API has no `/metrics` endpoint. Known observability gap.

**[BEST-9 — Best Practice]** `replicas: 2` on blue but no `PodDisruptionBudget`. During a node drain (e.g. Minikube upgrade) Kubernetes can evict both pods simultaneously, causing a brief outage. A PDB with `minAvailable: 1` prevents that.

---

### `worker-deployment.yaml`

**How it works:** Single replica background processor. Reads jobs from Redis queues, writes analytics events to ClickHouse and Postgres. No HTTP port — it never serves traffic directly.

**Working correctly:**
- `runAsNonRoot`, capabilities dropped, secrets from SealedSecrets
- Resource limits defined

**Issues found:**

**[BEST-3 — Best Practice]** No `readinessProbe`. Kubernetes marks the pod Ready at container start, before Redis/ClickHouse connections are established. If the worker crashes on startup it goes into a restart loop but traffic (queue jobs) may be dispatched to it during the brief window before the liveness probe triggers.

**[BUG — Bug]** No `/tmp` emptyDir volume despite `readOnlyRootFilesystem: true`. Node.js workers write to `/tmp` for temp files and module caching. The API has this; the worker doesn't — potential runtime crash if anything writes to `/tmp`.

**[BEST-NEW — Best Practice]** The `livenessProbe` is `exec: cat /proc/1/cmdline`. This only proves PID 1 is alive — which is always true unless the container has already crashed. It does not verify the worker is connected to Redis or actually processing jobs. A better approach: write a heartbeat file from the worker every N seconds and check its mtime, or add a lightweight HTTP health endpoint.

---

### `start-deployment.yaml` (Next.js dashboard)

**How it works:** Serves the Next.js frontend dashboard on port 3000. No direct database access — calls the API over HTTP.

**Working correctly:**
- `runAsNonRoot`, capabilities dropped
- Liveness and readiness probes on `GET /`
- Resource limits defined

**Issues found:**

**[BEST-4 — Best Practice]** Missing `readOnlyRootFilesystem: true`. The API and worker both set it. Next.js SSR also needs `/tmp` for page rendering — would need an emptyDir volume alongside the flag. Inconsistent security posture.

**[INFO — Informational]** `NEXT_PUBLIC_API_URL` is set in the ConfigMap. `NEXT_PUBLIC_*` variables are baked into the Next.js JavaScript bundle **at build time** by the Next.js compiler — they are not read at container start. Setting them in a ConfigMap only affects server-side code. If the image was built without these env vars as build args, the browser-side bundle will use whatever URL was compiled in (likely empty or a default). This is a Next.js-specific gotcha worth verifying.

---

### `migrate-job.yaml`

**How it works:** ArgoCD `PreSync` hook — runs `prisma migrate deploy` before every deployment. This guarantees DB schema is up to date before the new API pods start. `BeforeHookCreation` delete policy cleans up the old job before creating the new one. `backoffLimit: 3` retries on transient DB errors.

**Working correctly:**
- `PreSync` + `BeforeHookCreation` — correct hook lifecycle
- `ttlSecondsAfterFinished: 3600` — auto-cleans the completed job pod after 1 hour
- `readOnlyRootFilesystem: false` — necessary, Prisma writes to disk during migration. Documented with a comment.
- `backoffLimit: 3` — retries without looping forever

**Issues found:**

**[BUG-6 — Bug]** The migrate job (`app: openpanel-migrate`) has **no network policy** allowing it to reach Postgres. The `default-deny-all` policy blocks all egress by default. `allow-api-egress` targets `app: openpanel-api` — it does not cover the migrate job. `allow-db-ingress` only allows from `openpanel-api` and `openpanel-worker`. The migrate job would be silently blocked, fail all 3 retries, and abort the entire deployment as a PreSync failure.

**Fix needed:** Add a network policy allowing egress from `app: openpanel-migrate` to Postgres on port 5432, and update `allow-db-ingress` to also allow ingress from `app: openpanel-migrate`.

---

### `postgres-statefulset.yaml`

**How it works:** Single-replica StatefulSet with a PVC for persistence. Includes a `postgres-exporter` sidecar for Prometheus metrics and an `initContainer` that fixes `/var/run/postgresql` permissions before Postgres starts.

**Working correctly:**
- `postgres-exporter` sidecar — exposes metrics on port 9187
- `initContainer` to fix socket directory permissions — correct pattern for non-root Postgres
- PVC with `storageClassName: standard` — correct for Minikube
- Secrets from SealedSecrets for user/password

**Issues found:**

**[BEST-5 — Best Practice]** Both `livenessProbe` and `readinessProbe` use `tcpSocket: port: 5432`. This only checks the port is open — not that Postgres is accepting SQL. Postgres can be listening on the socket while still in crash recovery, initialising the data directory, or in read-only mode. The correct check is:
```yaml
exec:
  command: ["pg_isready", "-U", "$(POSTGRES_USER)", "-d", "openpanel"]
```

**[BEST-NEW — Best Practice]** The `postgres` container `securityContext` only sets `runAsNonRoot: true` and `runAsUser: 999`. Missing `allowPrivilegeEscalation: false`. The sidecar and initContainer do set it correctly — the main container should too.

---

### `clickhouse-statefulset.yaml`

**How it works:** Single-replica StatefulSet for ClickHouse analytics DB. Exposes native port (9000), HTTP port (8123), and Prometheus metrics port (9363) via a mounted config.

**Working correctly:**
- `/ping` liveness and readiness probes — correct ClickHouse health endpoint
- Prometheus metrics via configMap-mounted `prometheus.xml`
- `allowPrivilegeEscalation: false`, capabilities dropped

**Issues found:**

**[INFO-3 — Informational]** Image tag `clickhouse/clickhouse-server:24.12` is a partial version — pins the minor version but floats the patch. A CVE fix in `24.12.x` would auto-pull on pod restart. Pin to a full version like `24.12.3` for reproducibility.

---

### `redis-deployment.yaml`

**How it works:** Single-replica Redis with AOF persistence (`--appendonly yes`) and password auth (`--requirepass`). Includes a `redis-exporter` sidecar for Prometheus metrics. Data persisted via a PVC mounted at `/data`.

**Working correctly:**
- `redis-exporter` sidecar — metrics on port 9121
- AOF persistence + PVC for data durability
- Password injected from SealedSecret

**Issues found:**

**[BUG-7 — Bug]** Both `livenessProbe` and `readinessProbe` use `redis-cli ping` **without the `-a` flag**. Redis is started with `--requirepass`, so unauthenticated commands return `NOAUTH Authentication required` and redis-cli exits non-zero. The probes would fail on every check, triggering constant pod restarts.

**Fix needed:**
```yaml
exec:
  command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "ping"]
```

**[BEST-NEW — Best Practice]** The `redis` container has no container-level `securityContext`. Only the pod-level `securityContext` is set (`runAsNonRoot`, `runAsUser: 999`). Add `allowPrivilegeEscalation: false` and `readOnlyRootFilesystem: true` (Redis writes AOF to `/data` which is mounted — it only needs that PVC writable, not the whole filesystem).

**[INFO-6 — Informational]** `redis:7-alpine` floats the patch version. Pin to `redis:7.2.4-alpine` or similar for reproducibility.

---

### `network-policies.yaml`

**How it works:** Default-deny-all for both ingress and egress in the `openpanel` namespace. Explicit allow rules per service following least-privilege:

```
ingress-nginx ──→ openpanel-start:3000
ingress-nginx ──→ openpanel-api:3000
openpanel-start ──→ openpanel-api:3000
openpanel-api ──→ postgres:5432, clickhouse:8123/9000, redis:6379
openpanel-worker ──→ postgres:5432, clickhouse:8123/9000, redis:6379
observability ns ──→ redis:9121, postgres:9187, clickhouse:9363  (Prometheus scraping)
All pods ──→ *:53 UDP/TCP  (DNS)
```

**Working correctly:**
- Default deny-all — correct zero-trust baseline
- DNS egress allowed for all pods — required for service discovery
- Per-service ingress and egress rules — correct least-privilege
- Prometheus scraping allowed from `observability` namespace only

**Issues found:**

**[BUG-6 — Bug]** (same as migrate-job section) The migrate job is not covered by any allow rule. `allow-api-egress` and `allow-db-ingress` use `app: openpanel-api` — the migrate job has `app: openpanel-migrate`. Migrations are blocked at the network level and would fail silently.

**[INFO — Informational]** `allow-dns` uses `to: []` (all destinations on port 53). This is standard practice — restricting DNS to only kube-dns IPs would require knowing the ClusterIP, which changes per cluster. Acceptable.

---

### `ingress.yaml`

**How it works:** nginx Ingress with two virtual hosts:
- `openpanel.local` → `openpanel-start:3000` (Next.js dashboard)
- `api.openpanel.local` → `openpanel-api:3333` (API, which maps to container port 3000)

**Working correctly:**
- Correct service/port mapping (3333 matches `api-service.yaml`)
- `ingressClassName: nginx` explicit

**Issues found:**

**[BEST-7 — Best Practice]** No TLS on either virtual host. For a production-like presentation, add a commented-out cert-manager TLS block to show awareness of the production pattern:
```yaml
# tls:
#   - hosts: [openpanel.local]
#     secretName: openpanel-tls   # provisioned by cert-manager
```

---

### Staging overlay patches

**How it works:** Three strategic merge patches in `k8s/apps/overlays/staging/patches/` reduce replicas and resources for Minikube. Base has 2 replicas and production resource limits — staging patches them down.

**Working correctly:**
- `api-blue.yaml` — replicas: 1, cpu: 100m request / 500m limit, mem: 256Mi / 512Mi
- `start.yaml` — reduced cpu/mem requests to fit Minikube
- `worker.yaml` — reduced cpu/mem requests to fit Minikube
- StatefulSets (postgres, clickhouse) are not patched — their base limits are already Minikube-viable (postgres 2Gi, clickhouse 8Gi)

---

### `configmap.yaml`

**Working correctly:**
- `NODE_ENV: production`
- `CLICKHOUSE_SETTINGS_REMOVE_CONVERT_ANY_JOIN: "true"` — documented workaround for ClickHouse 24.x

**Issues found:**

**[INFO — Informational]** `NEXT_PUBLIC_API_URL: "http://openpanel-api:3333"` — this is a cluster-internal URL (`openpanel-api` service). Browser-side JavaScript cannot resolve cluster DNS names. This value is only useful for server-side Next.js code (SSR/API routes). Any browser fetch using this URL would fail. In practice this is likely fine because the start app routes API calls through Next.js server-side proxying — but worth verifying.

---

### Velero backup schedules

Daily schedule lives in `k8s/infrastructure/base/backup/velero/schedule.yaml` (all envs). Hourly schedule lives in `k8s/infrastructure/overlays/prod/resources/velero-schedule-hourly.yaml` (prod-only).

**[BUG-3 — Bug]** The `hourly-database-backup` schedule (prod overlay) uses `labelSelector: matchLabels: backup: database` but no Pod or PVC in the manifests carries this label. The hourly backup would capture nothing. The daily full backup is unaffected — it uses no label selector.

---

### AlertManager (`kube-prometheus-stack.yaml`)

**[BEST-6 — Documentation gap]** All alert routes point to the `null` receiver — no alerts are delivered. Correct for local dev but must be highlighted in the project defense with what would replace it in production (Slack webhook, PagerDuty, email SMTP).

---

## C. ArgoCD / GitOps

**Working correctly:**
- App of Apps bootstrap pattern with single `kubectl apply` bootstrap
- `resources-finalizer.argocd.argoproj.io` on all apps — prevents orphaned resources on delete
- `prune: true` + `selfHeal: true` + `allowEmpty: false` on all apps
- `retry` with exponential backoff on all apps
- AppProject scopes destinations to specific namespaces
- `ServerSideApply=true` on prometheus (required for large CRD manifests)

**Issues found:**

**[INFO-1 — Informational]** Bootstrap app uses `project: default` (not `project: openpanel`). This is intentional — the bootstrap needs cluster-wide permission to create Application objects across all ArgoCD projects. Documented.

**[INFO — Informational]** SealedSecrets are not tracked by an ArgoCD Application. They are applied manually via `make sealed-secrets`. This is a common pattern (avoids ArgoCD accidentally pruning secrets) but means secret drift is not GitOps-enforced.

---

## D. Security

**Working correctly:**
- Gitleaks secret scanning with `fetch-depth: 0` (full history)
- Trivy container image scanning with SARIF upload
- SBOM generation per image
- Sealed Secrets — no plaintext secrets ever committed
- Network policies — default deny-all, explicit allow rules per service
- Non-root containers, all capabilities dropped
- `.gitleaks.toml` allowlist limited to sealed blobs and LocalStack test credentials

**Issues found:**

**[SEC-2 — Security]** Tool downloads without checksum verification — **fixed in this session** (ci-validate.yml).

**[SEC-3 — Security]** GitHub Actions pinned to mutable version tags, not immutable commit SHAs. Addressed by adding `dependabot.yml`. Full SHA pinning is the next hardening step.

**[SEC-1 — Security]** CD workflow missing `permissions: read-all` — **fixed in this session** (cd-update-tags.yml).

---

## E. Makefile & Scripts

**Working correctly:**
- `set -euo pipefail` in all scripts — fail fast on errors
- Idempotent installs (`helm upgrade --install`)
- Prerequisite version checks before executing
- `reseal-secrets` with sensible defaults and documented override pattern

**Issues found:**

**[INFO — Informational]** `make open` uses `xdg-open` (Linux only). Documented as Linux-specific.

**[INFO — Informational]** `setup-github` adds `credentials-velero.example` to the initial commit. This file contains example credential patterns only — confirmed safe.

---

## Previous Fixes Already Committed to Repo

These issues were encountered during development and resolved in prior commits on `master`.

### Fix 1 — `ServerSideApply=true` for Prometheus (`commit ac47ec3`)

**Problem:** `kube-prometheus-stack` installs very large CRDs. Client-side apply stores the full manifest in the `kubectl.kubernetes.io/last-applied-configuration` annotation. These CRD manifests exceed Kubernetes' 256 KB annotation size limit — ArgoCD sync failed.

**Fix:** `ServerSideApply=true` added to `syncOptions` in `observability-prometheus-app.yaml`. Server-side apply moves field ownership tracking to the API server and bypasses the annotation size limit entirely.

### Fix 2 — AppProject `clusterResourceWhitelist` expanded (`commit c907448`)

**Problem:** `kube-prometheus-stack` installs cluster-scoped resources (`ClusterRole`, `ClusterRoleBinding`, `CustomResourceDefinition`, `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`). The AppProject didn't list these, so ArgoCD refused to create them.

**Fix:** `clusterResourceWhitelist` in `openpanel-project.yaml` expanded to include all required cluster resource types.

### Fix 3 — DB migrations job and ClickHouse 24.x compatibility (`commit 3f4a34f`)

**Problem 1:** No automated database migrations before deployment.  
**Fix:** `migrate-job.yaml` added as an ArgoCD `PreSync` hook running `prisma migrate deploy`.

**Problem 2:** ClickHouse 24.x removed the setting `query_plan_convert_any_join_to_semi_or_anti_join`. The API client attempted to set it on connection — unknown setting error.  
**Fix:** `CLICKHOUSE_SETTINGS_REMOVE_CONVERT_ANY_JOIN=true` added to the ConfigMap.

---

## Live Cluster State vs Repo (audit 2026-04-02)

### What matches ✓

| Resource | Status |
|----------|--------|
| All openpanel pods | Running and Ready |
| Image tag on all deployments | `main-aef4b94` — matches repo |
| API service selector | `version: blue` — correct |
| All PVCs | Bound (postgres 5Gi, clickhouse 10Gi, redis 2Gi) |
| Sealed Secrets (4 secrets) | Present in cluster |
| Network policies (8 policies) | Present and match repo |
| ArgoCD pods | All Running |
| Observability (prometheus, promtail, tempo, grafana, alertmanager) | Synced + Healthy |
| Backup (minio) | Synced + Healthy |
| Sealed Secrets controller | Running |

### Drift found — fix before merging to master

**[DRIFT-1]** Bootstrap Application is missing its `automated` syncPolicy. Live bootstrap has only `syncOptions: [CreateNamespace=false]` — no `automated: {prune: true, selfHeal: true}`. Bootstrap is permanently `OutOfSync` but will never auto-heal. Root cause: manual kubectl edits during `commit 5290bf2` testing.

**Fix:**
```bash
kubectl apply -f k8s/infrastructure/argocd/bootstrap-app.yaml
```

**[DRIFT-2]** `openpanel` ArgoCD Application has `targetRevision: test/ci-pipeline-validation` instead of `master`. Was manually set via ArgoCD UI during testing. Will auto-correct once DRIFT-1 is fixed (~3 min reconcile cycle).

### Bug found and fixed — Loki `Unknown` sync status

**[LOKI-1 — Fixed in this session]** Loki Helm chart >= 6.0 requires a `schemaConfig` block. The `loki.yaml` values file did not have one, causing Helm template rendering to fail. ArgoCD could not compute the desired state → `Unknown` sync status. Existing Loki pods continued running from the last successful deployment, but any future sync would fail.

**Fix applied:** `schemaConfig` added to `k8s/infrastructure/base/observability/loki.yaml` with the recommended `v13 + tsdb + filesystem` schema.

### Recommended remediation order

```bash
# 1. Commit and push the loki.yaml fix and workflow improvements
git add k8s/infrastructure/base/observability/loki.yaml .github/
git commit -m "fix: add schemaConfig to Loki, harden CI/CD workflows"
git push

# 2. Merge test/ci-pipeline-validation → master when ready

# 3. Restore bootstrap self-healing
kubectl apply -f k8s/infrastructure/argocd/bootstrap-app.yaml

# 4. Verify — bootstrap reconciles and openpanel reverts to master
kubectl get applications -n argocd -w
```

---

## Summary Table

| ID | Area | Description | Severity | Status |
|----|------|-------------|----------|--------|
| BUG-1 | CD workflow | No concurrency guard → git push conflicts | **Bug** | Fixed |
| BUG-2 | K8s overlay | resource-limits.yaml patch is a no-op (only adds annotation, no limits) | **Bug** | Open |
| BUG-3 | Velero | Hourly backup label selector matches nothing | **Bug** | Open |
| BUG-6 | Network policy | migrate-job has no egress rule → migrations blocked at network layer | **Bug** | Open |
| BUG-7 | Redis | Liveness/readiness probe uses redis-cli ping without -a (auth fails) | **Bug** | Open |
| BUG-4 | CI build | SBOM and Trivy scanned `:latest` not built SHA | **Bug** | Fixed |
| LOKI-1 | Observability | Missing schemaConfig — Loki sync broken | **Bug** | Fixed |
| DRIFT-1 | ArgoCD | Bootstrap missing automated syncPolicy | **Drift** | Open (manual fix) |
| DRIFT-2 | ArgoCD | openpanel app on wrong branch | **Drift** | Open (auto after DRIFT-1) |
| SEC-1 | CD workflow | Missing `permissions: read-all` | Security | Fixed |
| SEC-2 | CI validate | Checksums fetched from same server as binary (zero protection) | Security | Fixed — hardcoded SHA256 in workflow |
| SEC-3 | All workflows | Actions pinned to tags not SHAs | Security | Partially mitigated (dependabot.yml added) |
| BEST-1 | All workflows | No concurrency cancellation groups | Best Practice | Fixed |
| BEST-2 | CI validate | kubeconform skipped all CRDs | Best Practice | Fixed |
| BEST-3 | Worker | No readinessProbe | Best Practice | Open |
| BEST-4 | Start deploy | Missing readOnlyRootFilesystem | Best Practice | Open |
| BEST-5 | PostgreSQL | tcpSocket probe instead of pg_isready | Best Practice | Open |
| BEST-6 | AlertManager | All alerts dropped to null receiver | Documentation gap | Open |
| BEST-7 | Ingress | No TLS | Best Practice | Open |
| BUG-5 | CD workflow | Bot commit triggers CI → infinite loop (missing [skip ci]) | **Bug** | Fixed |
| BEST-8 | GitHub | No dependabot.yml; schedule changed from weekly → daily | Best Practice | Fixed |
| BEST-9 | All deploys | No HPA or PDB | Best Practice | Open |
| BEST-10 | Worker | livenessProbe is cat /proc/1/cmdline — doesn't verify worker health | Best Practice | Open |
| BEST-11 | Postgres | Main container missing allowPrivilegeEscalation: false | Best Practice | Open |
| BEST-12 | Redis | Container missing securityContext (allowPrivilegeEscalation, readOnlyRootFilesystem) | Best Practice | Open |
| INFO-1 | ArgoCD | Bootstrap uses project: default (intentional) | Informational | N/A |
| INFO-2 | CD workflow | git push without branch specification | Minor | Fixed |
| INFO-3 | ClickHouse | Partial version tag (24.12) | Minor | Open |
| INFO-4 | CI build | SBOM generated but not attested | Minor | Open |
| INFO-5 | Blue-green | Green deployment not updated by CD (by design) | Minor / By design | Documented |
| INFO-6 | Redis/PG | Floating minor version tags | Minor | Open |
| MIGRATE | CD workflow | migrate-job.yaml not updated with new image tag | **Bug** | Fixed |
| FAIL-FAST | CI build | Matrix used default fail-fast: true | Best Practice | Fixed |
| TIMEOUT | All workflows | No timeout-minutes on any job | Best Practice | Fixed |
| EXTRA-1 | ci-validate | Dead REGISTRY/IMAGE_PREFIX env vars never used | Code quality | Fixed |
| EXTRA-2 | ci-validate | secret-scan missing pull-requests: write for PR annotations | Permissions | Fixed |
