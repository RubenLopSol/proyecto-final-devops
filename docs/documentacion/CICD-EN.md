# CI/CD — Continuous Integration and Deployment Pipeline

**Final Project — Master in DevOps & Cloud Computing**

---

## Overview

The CI/CD pipeline is implemented with **GitHub Actions** and follows this flow:

```
Developer pushes code / opens PR
           │
           ▼
  ci-validate.yml                    ← triggered by push or pull_request
  CI-Lint-Test-Validate
  ├── lint-and-test    (commented — disabled, see note)
  ├── validate-infra
  └── secret-scan
           │
           │ completes successfully
           ▼
  ci-build-publish.yml                          ← triggered by workflow_run on ci-validate.yml
  CI-Build-Publish               ← ONLY on master/main, never on PRs
  └── build-and-push
      └── security-scan
           │
           │ completes successfully
           ▼
  cd-update-tags.yml                 ← triggered by workflow_run on ci-build-publish.yml
  CD-Update-GitOps-Manifests
  └── update-manifests
      └── commits new image tags to Git
           │
           ▼
      ArgoCD detects the new commit
      and deploys automatically
```

> On a **Pull Request** the chain stops after `ci-validate.yml`. `ci-build-publish.yml` only triggers on `master`/`main`, so PRs never build or publish images.

![CI/CD GitOps Flow](../diagrams/img/flujo_CICD.png)

---

![GitHub Actions — CI Pipeline completed successfully](../screenshots/github-actions-ci-success.png)

---

## Why three workflow files

The pipeline is split into three files with distinct responsibilities. This is not an aesthetic choice — it has a technical and cost-driven reason:

| File | Name | Responsibility |
|---|---|---|
| `ci-validate.yml` | `CI-Lint-Test-Validate` | Quality gate: validates code before and after merging |
| `ci-build-publish.yml` | `CI-Build-Publish` | Builds and publishes Docker images to GHCR |
| `cd-update-tags.yml` | `CD-Update-GitOps-Manifests` | Updates image tags in the Kubernetes manifests |

**The core reason is the separation between validation and publication.**

Mixing lint, tests, and build into a single file creates a problem: on every Pull Request, the build and push steps would run even though the code may never be merged. That means publishing Docker images from development branches to the production registry, wasting runner minutes unnecessarily, and generating noise in the image history.

By separating them, the behaviour is correct:

- `ci-validate.yml` runs on **every** PR and every push — it validates Kubernetes manifests and scans for secrets, and acts as a barrier before anything reaches master.
- `ci-build-publish.yml` only runs **after** `ci-validate.yml` passes on master — that is the only moment when publishing an image to the registry makes sense.
- `cd-update-tags.yml` only runs **after** `ci-build-publish.yml` finishes — it updates the manifests with the new tag so ArgoCD can deploy it.

---

# CI Pipeline — `ci-validate.yml`

Name: **`CI-Lint-Test-Validate`**

It runs in three situations:

| Trigger | When | Why |
|---|---|---|
| `pull_request` | When opening or updating a PR targeting `master`/`main` | Validates the code **before merging** — this is the quality gate |
| `push` | When merging to `master`/`main` | Validation **after merging** and the starting point of the chain towards `ci-build-publish.yml` |
| `workflow_dispatch` | Manually from the GitHub Actions UI | Allows running the pipeline without needing to push a commit |

Changes that only affect documentation (`**.md`, `docs/**`, `.gitignore`) do not trigger the pipeline.

### Why it runs on both PR and push to master

It may seem redundant to run the same validation twice, but there are three concrete reasons:

**1. It is the starting point of the chain.**
`ci-build-publish.yml` is triggered via `workflow_run` listening to `ci-validate.yml`. If `ci-validate.yml` did not run on push to master, `ci-build-publish.yml` would never have an event to react to — the entire chain would break.

**2. It protects against direct pushes to master.**
If someone pushes directly to master without going through a PR, the `pull_request` validation never ran. The `push` trigger ensures the code is validated regardless.

**3. It validates the result of the merge, not just the branch.**
When a PR is approved, CI validated the development branch. But the merge itself can introduce conflicts or unexpected changes. The `push` trigger validates the final state of master after the merge.

### Pipeline Jobs

```
CI-Lint-Test-Validate
├── lint-and-test          ← DISABLED (intentionally commented — see note)
├── validate-infra         ← Parallel
└── secret-scan            ← Parallel
```

> **Note — `lint-and-test` intentionally disabled:** This is a DevOps project, not an application project. Linting, type-checking, and testing of the OpenPanel source code is the responsibility of the application team, not the infrastructure pipeline. The job is commented out in `ci-validate.yml` (not deleted) so it can be re-enabled if the project takes ownership of the source code. The CI here focuses on what matters for DevOps: valid and secure Kubernetes manifests, and no exposed secrets.

---

# Build Pipeline — `ci-build-publish.yml`

Name: **`CI-Build-Publish`**

Triggered automatically when `CI-Lint-Test-Validate` completes successfully on `master`/`main`. It has no manual trigger of its own — if you need to run it manually, trigger `ci-validate.yml` from the UI and if it passes, the build fires automatically through the chain. This ensures the validation gate is never bypassed.

### Pipeline Jobs

```
CI-Build-Publish
└── build-and-push         ← Runs only if the CI gate passed successfully
    └── security-scan      ← Depends on build-and-push
```

---

### Job: Lint & Test (App) — DISABLED

This job is **intentionally commented out** in `ci-validate.yml`. The reason: this is a DevOps project whose goal is to deploy and operate the OpenPanel application reliably, not to maintain its source code. Application linting (ESLint, TypeScript, unit tests) is the responsibility of the application team.

The job code remains commented out in the workflow so it can be re-enabled if the project takes ownership of the OpenPanel source code.

---

### Job: Validate Infrastructure

Tools are installed directly from their official releases with pinned versions — no dependency on third-party Actions such as Azure. kubectl includes SHA256 checksum verification to guarantee binary integrity.

Versions are declared in the job-level `env:` block — defined once at the top, no hardcoded values scattered across every `curl` command. To update a version, change one line.

```yaml
env:
  KUBECTL_VERSION: "v1.28.0"
  KUSTOMIZE_VERSION: "v5.3.0"
  KUBECONFORM_VERSION: "v0.6.4"
  KUBE_LINTER_VERSION: "v0.6.4"
  HADOLINT_VERSION: "v2.12.0"
```

| Tool | Version | Installation source |
|---|---|---|
| `kubectl` | `v1.28.0` | `dl.k8s.io` (official Kubernetes) + SHA256 verification |
| `kustomize` | `v5.3.0` | GitHub releases (`kubernetes-sigs/kustomize`) |
| `kubeconform` | `v0.6.4` | GitHub releases (`yannh/kubeconform`) |
| `kube-linter` | `v0.6.4` | GitHub releases (`stackrox/kube-linter`) |
| `hadolint` | `v2.12.0` | GitHub releases (`hadolint/hadolint`) |

| Step | Tool | What it validates |
|---|---|---|
| `kustomize build k8s/apps/overlays/staging` + `kustomize build k8s/apps/overlays/prod` | Kustomize v5.3.0 | Both overlays generate valid YAML |
| `kubeconform` (verbose, strict) | kubeconform v0.6.4 | Manifests comply with Kubernetes 1.28 schemas |
| `kube-linter lint --config .kube-linter.yaml` | kube-linter v0.6.4 | Selective checks defined in `.kube-linter.yaml` (see detail below) |
| `hadolint --failure-threshold error` | hadolint v2.12.0 | Dockerfile linting (API, Start, Worker) — only errors block the pipeline, warnings are ignored |

> **`kubectl apply --dry-run=client` is not used** — it was removed from the pipeline because it required a real or simulated kubeconfig to connect to the API server. kubeconform covers schema validation more robustly and without cluster dependencies.

#### kube-linter configuration — `.kube-linter.yaml`

The `.kube-linter.yaml` file at the root of the repository defines a **selective** set of checks instead of enabling all built-ins:

| Mode | Value |
|---|---|
| `addAllBuiltIn` | `false` — only explicitly included checks run |

| Included check | What it detects |
|---|---|
| `latest-tag` | Images using the `latest` tag (non-reproducible) |
| `unset-cpu-requirements` | Containers without `resources.requests/limits` for CPU |
| `unset-memory-requirements` | Containers without `resources.requests/limits` for memory |
| `privilege-escalation-container` | Containers without `allowPrivilegeEscalation: false` |
| `writable-host-mount` | Volumes mounted from the host with write permissions |

Checks **explicitly excluded** (with justification):

| Excluded check | Reason |
|---|---|
| `no-anti-affinity` | Single-node Minikube cluster — anti-affinity does not apply |
| `no-read-only-root-fs` | Databases (postgres, clickhouse) and init containers need a writable filesystem |
| `run-as-non-root` | The `fix-permissions` init container must run as root to `chown` volumes |
| `non-isolated-pod` | Network Policies are managed in separate manifests, not in deployments |

#### hadolint configuration — `.hadolint.yaml`

The `.hadolint.yaml` file at the root ignores two rules from upstream Dockerfiles that are not the project's responsibility:

| Ignored rule | Description |
|---|---|
| `DL3008` | Pinning versions in `apt-get install` — upstream code, not the pipeline's responsibility |
| `DL3059` | Consecutive `RUN` instructions not consolidated — upstream code, not the pipeline's responsibility |

With `--failure-threshold error`, hadolint **only blocks the pipeline** if it finds real errors (e.g. incorrect Dockerfile syntax). Warnings, including those ignored via `.hadolint.yaml`, do not interrupt the build.

---

### Job: Secret Detection

Run with **Gitleaks** over the full repository history (`fetch-depth: 0`).

- Detects tokens, passwords, and keys in plain text
- Blocks the pipeline if exposed secrets are found

---

### Job: Build & Push Images

**Only runs on push to `main`/`master`** (not on PRs).

#### Reusable actions (`uses`)

GitHub Actions allows reusing predefined actions published by third parties. Instead of coding each step from scratch, they are called with `uses: author/action@version` and configured with `with:`.

The actions used in this job:

| Action | Author | What it does |
|---|---|---|
| `actions/checkout@v4` | GitHub | Downloads the repository code to the virtual machine |
| `docker/login-action@v3` | Docker | Logs in to GHCR using the provided credentials |
| `docker/setup-buildx-action@v3` | Docker | Configures the advanced Docker build engine (multi-platform, cache) |
| `docker/metadata-action@v5` | Docker | Automatically calculates image tags based on the push type (SHA, latest, semver, PR) |
| `docker/build-push-action@v5` | Docker | Builds the Docker image and pushes it to the registry with the calculated tags |

> `docker/metadata-action` is the key piece: it looks at the event context (normal push, version tag, PR) and decides which tags to apply automatically. Its result is passed to the next step via `${{ steps.meta.outputs.tags }}`.

Builds and publishes 3 images in parallel using `strategy.matrix`:

| Service | Image published to GHCR |
|---|---|
| `api` | `ghcr.io/rubenlopsol/openpanel-api` |
| `start` | `ghcr.io/rubenlopsol/openpanel-start` |
| `worker` | `ghcr.io/rubenlopsol/openpanel-worker` |

### Tag strategy

| Trigger | Generated tag |
|---|---|
| Push to main | `main-<sha7>` (e.g.: `main-dfc2ddf`) |
| Push to main | `latest` |
| Semver tag | `v1.2.3` |
| Pull Request | `pr-<number>` |

### Docker Cache

GitHub Actions Cache (`type=gha`) is used to speed up builds:

```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

---

### Job: Generate SBOM

**anchore/sbom-action** generates a Software Bill of Materials (SBOM) for each of the 3 published images, in SPDX-JSON format.

- Runs inside the same `build-and-push` job, immediately after the image is published
- The SBOM is uploaded as a workflow artifact with a 5-day retention
- Allows auditing exactly which packages and dependencies are included in each published image
- Required in modern supply chain security pipelines (SLSA, SSDF)

---

### Job: Security Scan

**Trivy** scans the 3 published images for `CRITICAL` and `HIGH` vulnerabilities.

- Results are uploaded as SARIF to the GitHub Security Tab with `if: always()` — the SARIF is uploaded even when Trivy exits non-zero
- `exit-code: "1"` — the step fails if vulnerabilities with a patch available are found
- `ignore-unfixed: true` — ignores vulnerabilities without a published patch (cannot be fixed locally)

---

# CD Pipeline — `cd-update-tags.yml`

![GitHub Actions — CD Pipeline completed successfully](../screenshots/github-actions-cd-success.png)

The CD pipeline runs automatically **when CI finishes successfully**.

### Trigger

```yaml
on:
  workflow_run:
    workflows: ["CI-Build-Publish"]
    types: [completed]
    branches: [master, main]
```

### Job: Update Image Tags

This job updates the Kubernetes manifests directly in Git:

```bash
# 1. Updates the image tag in the 3 deployments
sed -i "s|image: ghcr.io/.*/openpanel-api:.*|image: ghcr.io/<owner>/openpanel-api:main-<sha>|g" \
  k8s/apps/base/openpanel/api-deployment-blue.yaml
# (same for start-deployment.yaml and worker-deployment.yaml)

# 2. Updates the ArgoCD Application targetRevision to the new release tag
sed -i "s|targetRevision:.*|targetRevision: release/main-<sha>|" \
  k8s/infrastructure/argocd/applications/openpanel-app.yaml

# 3. Commit with all changes (images + ArgoCD Application)
git commit -m "chore: update image tags to main-<sha>"
git push

# 4. Create and push the release tag (immutable reference to this deployment)
git tag "release/main-<sha>"
git push origin "release/main-<sha>"
```

The ArgoCD bootstrap detects the change to `openpanel-app.yaml` (now pointing to tag `release/main-<sha>`) and re-applies the Application. ArgoCD then syncs openpanel from that exact tag — the commit containing the updated image tags.

The `release/main-<sha>` tag is immutable. To roll back to any previous version, update `targetRevision` in `openpanel-app.yaml` to the desired tag and push.

---

## Versioning Strategy

The project follows **Semantic Versioning (SemVer)** for official releases.

| Change type | Version tag | Example |
|---|---|---|
| Production release | `vMAJOR.MINOR.PATCH` | `v1.2.0` |
| Development build | `main-<sha7>` | `main-dfc2ddf` |
| Pull Request | `pr-<num>` | `pr-42` |

---

## Pipeline Permissions

Each workflow declares `permissions: read-all` at the workflow level as a restrictive default. Jobs that need more permissions declare them explicitly in their `permissions:` block, overriding only what is necessary.

| Workflow | Workflow-level permission | Job-level overrides |
|---|---|---|
| `ci-validate.yml` | `read-all` | — |
| `ci-build-publish.yml` | `read-all` | `build-and-push`: `packages: write`, `id-token: write` / `security-scan`: `security-events: write` |
| `cd-update-tags.yml` | — | `update-manifests`: `contents: write` |

This follows the principle of least privilege: jobs that do not need to write cannot do so.

---

## Pipeline Variables and Secrets

### Variables (`vars.`)

> No manual variables are needed. All workflows use `github.repository_owner` (a built-in context variable) instead of `vars.REGISTRY_OWNER`. Images are always published under the same owner without any additional configuration.

### Secrets (`secrets.`)

| Secret | Usage |
|---|---|
| `GITHUB_TOKEN` | Login to GHCR for image push (automatic) |
| `GITHUB_TOKEN` | Gitleaks for secret scanning |

No additional secrets are needed thanks to the use of the automatic GitHub Actions token.

---

## Verifying Pipeline Status

```bash
# View the last workflow runs
gh run list --limit 10

# View details of a specific run
gh run view <run-id>

# View the jobs of a run
gh run view <run-id> --log

# Verify that the image was published to GHCR
gh api /users/rubenlopsol/packages/container/openpanel-api/versions \
  --jq '.[0].metadata.container.tags'
```
