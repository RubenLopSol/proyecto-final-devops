# Security — Secrets, Network Policies, RBAC and Hardening

**Final Project — Master in DevOps & Cloud Computing**

---

## Overview

Security is applied at multiple layers:

| Layer | Mechanism | Tool |
|---|---|---|
| Secrets in Git | Encrypted with cluster key | Sealed Secrets |
| Controller private key | Out-of-cluster backup | AWS Secrets Manager |
| Secrets in CI pipeline | Encrypted repository variables | GitHub Secrets |
| Network traffic | Allow/deny rules per pod | Network Policies |
| Pod permissions | Non-root, read-only filesystem | SecurityContext |
| ArgoCD permissions | Minimal per component | RBAC + ServiceAccount |
| Container images | Vulnerability scanning | Trivy (in CI) |

---

## Sealed Secrets — Secrets in Git

In GitOps, everything must be in Git — including secrets. **Sealed Secrets** allows committing encrypted secrets safely.

### How it works — Complete data flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  CREATION (once per secret)                                             │
│                                                                         │
│  Developer                                                              │
│     │                                                                   │
│     │  kubectl create secret --dry-run -o yaml                         │
│     ▼                                                                   │
│  Secret YAML (plaintext) — in memory/pipe only, never written to disk  │
│     │                                                                   │
│     │  kubeseal --cert <public-key>                                     │
│     ▼                                                                   │
│  SealedSecret YAML (RSA-OAEP encrypted) ──► git commit ──► GitHub      │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  DEPLOYMENT (automatic via ArgoCD)                                      │
│                                                                         │
│  GitHub                                                                 │
│     │                                                                   │
│     │  ArgoCD detects change in overlays/staging/sealed-secrets/        │
│     ▼                                                                   │
│  kubectl apply SealedSecret ──► Kubernetes API                         │
│                                      │                                  │
│                                      │  Sealed Secrets Controller       │
│                                      │  (watches SealedSecret resources)│
│                                      ▼                                  │
│                              Decrypts with RSA private key              │
│                                      │                                  │
│                                      ▼                                  │
│                              Creates native Kubernetes Secret           │
│                                      │                                  │
│                                      ▼                                  │
│                              Pod reads the Secret via envFrom/volume    │
└─────────────────────────────────────────────────────────────────────────┘
```

**Why committing SealedSecrets is safe:**

The encryption uses **RSA-OAEP** with the cluster's public key. The result is an encrypted blob that can only be decrypted by the controller holding the corresponding private key. Without cluster access, the blob is useless.

### The private key — where it lives and how it is protected

When the controller is installed for the first time (`make sealed-secrets`), it automatically generates an RSA-4096 key pair and stores it as a Kubernetes Secret in the `sealed-secrets` namespace:

```bash
# View the generated key
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key
# NAME                        TYPE                DATA
# sealed-secrets-key-xxxxx    kubernetes.io/tls   2   ← tls.crt (public) + tls.key (private)
```

**Risk:** if the cluster is destroyed, the key is lost and existing SealedSecrets can no longer be decrypted. That is why the key is backed up in AWS Secrets Manager.

### Key backup in AWS Secrets Manager

The controller configuration lives in `k8s/infrastructure/base/sealed-secrets/values.yaml` — resources, nodeSelector, securityContext and metrics. The Makefile passes it with `--values` on install.

Terraform provisions the Secrets Manager slot (`terraform/modules/backup-storage/main.tf`, called from each environment):

```hcl
resource "aws_secretsmanager_secret" "sealed_secrets_key" {
  name = "devops-cluster/sealed-secrets-master-key"
}
```

After installing the controller, back up the key:

```bash
# Export the key from the cluster and store it in Secrets Manager (LocalStack)
make backup-sealing-key

# For real AWS (without LocalStack), pass an empty endpoint:
make backup-sealing-key LOCALSTACK_ENDPOINT=""
```

### Recovering on a new cluster

```bash
# 1. Install the controller via kustomize (same method as normal setup)
make sealed-secrets ENV=staging

# 2. If you have a backup of the RSA key, restore it before ArgoCD syncs
make restore-sealing-key
# The controller decrypts the existing SealedSecrets in the repo without resealing

# If you do NOT have a key backup, regenerate secrets with the new cluster key:
make reseal-secrets ENV=staging
git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
git commit -m "chore: reseal secrets for new cluster"
git push
```

### Managed secrets

All secrets are stored in **one file per environment**, generated by `make reseal-secrets`:

```
k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
k8s/infrastructure/overlays/prod/sealed-secrets/secrets.yaml
```

| Section | Secret | Target namespace | Contents |
|---|---|---|---|
| § 1 | `postgres-credentials` | `openpanel` | PostgreSQL username and password |
| § 2 | `redis-credentials` | `openpanel` | Redis password |
| § 3 | `clickhouse-credentials` | `openpanel` | ClickHouse username and password |
| § 4 | `openpanel-secrets` | `openpanel` | DATABASE_URL, CLICKHOUSE_URL, REDIS_URL, API_SECRET |
| § 5 | `grafana-admin-credentials` | `observability` | Grafana admin username and password |
| § 6 | `minio-credentials` | `backup` | MINIO_ROOT_USER, MINIO_ROOT_PASSWORD |

The controller lives in the `sealed-secrets` namespace but creates Secrets in the namespace declared in each SealedSecret (openpanel, observability, backup). Pods can only read Secrets in their own namespace — which is why each secret targets the namespace where the pod expects to find it.

![Sealed Secrets — SealedSecrets managed by ArgoCD](../screenshots/sealed-secrets-argocd.png)

### Rotating or updating secrets

All secrets are regenerated at once with a single command:

```bash
# Rotate one or more credentials (the rest use .secrets values or defaults)
make reseal-secrets ENV=staging POSTGRES_PASSWORD=new-pass

# Commit the new secrets.yaml (values are RSA-encrypted blobs, safe to commit)
git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
git commit -m "chore: rotate postgres credentials"
git push
# ArgoCD (sealed-secrets app) applies the change automatically
```

### Verifying that the Secret is decrypted

```bash
# The controller creates the Secret automatically
kubectl get secret new-secret -n openpanel

# View the decrypted value (only if you have permissions in the cluster)
kubectl get secret new-secret -n openpanel \
  -o jsonpath='{.data.key}' | base64 -d
```

![Sealed Secrets — Secrets automatically decrypted in the openpanel namespace](../screenshots/sealed-secrets-decrypted.png)

---

## Network Policies — Network Segmentation

A **deny-by-default** model is applied: all traffic is blocked by default, and only explicitly necessary connections are permitted.

### Policies applied in the `openpanel` namespace

| Policy | Type | Description |
|---|---|---|
| `default-deny-all` | Ingress + Egress | Blocks all traffic by default |
| `allow-dns` | Egress | Allows DNS resolution (UDP/TCP 53) for all pods |
| `allow-api-ingress` | Ingress | API accepts traffic only from the Ingress Controller and the Dashboard |
| `allow-api-egress` | Egress | API can connect to PostgreSQL (5432), ClickHouse (8123/9000), Redis (6379) |
| `allow-worker-egress` | Egress | Worker can connect to PostgreSQL, ClickHouse and Redis |
| `allow-start-ingress` | Ingress | Dashboard accepts traffic only from the Ingress Controller |
| `allow-start-egress` | Egress | Dashboard can connect only to the API (3000) |
| `allow-db-ingress` | Ingress | Databases accept connections only from the API and Worker |
| `allow-prometheus-scraping` | Ingress | Exporters (9121, 9187, 9363) accept scraping from the `observability` namespace |

### Allowed connectivity diagram

![Allow connect](../diagrams/img/allow_connect.png)


---

## SecurityContext — Non-Root Containers

All pods are configured to run as a non-root user:

```yaml
# Example in the API deployment
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    fsGroup: 1001
  containers:
    - name: api
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
```

The same pattern is applied in Grafana (user 472), Prometheus and the other components of the observability stack.

---

## RBAC — Least Privilege

Each component has its own **ServiceAccount** with only the necessary permissions.

### Prometheus

Prometheus needs read permissions on cluster resources for target auto-discovery (nodes, pods, services, endpoints and ingresses).

The Prometheus RBAC (ClusterRole + ClusterRoleBinding + ServiceAccount) is managed automatically by the **`kube-prometheus-stack`** chart when deployed via ArgoCD. There is no need to maintain manual RBAC YAML files.

```yaml
# Permissions applied by the chart internally:
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
```

### Promtail

Promtail needs permissions to list pods and read their logs. As with Prometheus, the RBAC is managed automatically by the **`grafana/promtail`** chart:

```yaml
# Permissions applied by the chart internally:
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
```

### ArgoCD

ArgoCD has its own RBAC system. The `openpanel` AppProject limits applications to the `openpanel`, `observability`, `backup`, `sealed-secrets` and `kube-system` namespaces. The Sealed Secrets controller needs access to `sealed-secrets` to manage the RSA key and to the other namespaces to create the decrypted Secrets.

---

## Image Scanning with Trivy

**Trivy** runs in the CI pipeline after each image build.

```yaml
# .github/workflows/ci-build-publish.yml — security-scan job
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@0.28.0
  with:
    image-ref: "ghcr.io/<owner>/openpanel-api:latest"
    format: "sarif"
    severity: "CRITICAL,HIGH"
    exit-code: "1"         # Blocks the pipeline if vulnerabilities with a patch available are found
    ignore-unfixed: true   # Ignores vulnerabilities without a published patch (cannot be fixed locally)
```

Results are automatically uploaded to the **Security** tab of the GitHub repository (SARIF format) with `if: always()` — the SARIF is uploaded even if Trivy fails.

---

## GitHub Secrets — CI Pipeline Secrets

The tokens required in the pipeline are managed as GitHub Secrets (encrypted in GitHub):

| Secret | Usage |
|---|---|
| `GITHUB_TOKEN` | Login to GHCR for image push (automatic, no configuration required) |

No additional secrets need to be configured manually — GitHub provides `GITHUB_TOKEN` automatically in every workflow run.

---

## Verifying Security Status

```bash
# Verify that no pod runs as root
kubectl get pods -n openpanel -o jsonpath=\
  '{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext.runAsUser}{"\n"}{end}'

# Verify active Network Policies
kubectl get networkpolicies -n openpanel

# Verify decrypted Sealed Secrets
kubectl get secrets -n openpanel

# View events of the Sealed Secrets controller
kubectl logs -n sealed-secrets \
  deployment/sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```
