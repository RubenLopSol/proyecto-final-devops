# Terraform — Infrastructure Provisioning

**Final Project — Master in DevOps & Cloud Computing**

---

## What this directory does

Terraform provisions the external storage infrastructure the cluster depends on for two things:

1. **S3 bucket** — where Velero writes daily Kubernetes backups
2. **Secrets Manager slot** — stores the Sealed Secrets controller RSA key so that a destroyed and rebuilt cluster can decrypt existing SealedSecrets without re-sealing

Terraform creates the empty slots. The actual content is written later by Makefile targets: `make backup-sealing-key` and Velero respectively.

---

## Directory structure

```
terraform/
├── modules/                        ← Reusable logic (no environment-specific values)
│   ├── backup-storage/             ← S3 bucket + Secrets Manager slot
│   │   ├── versions.tf             # Provider requirements
│   │   ├── main.tf                 # Resources
│   │   ├── variables.tf            # Inputs
│   │   └── outputs.tf              # Outputs: bucket ARN, secret ARN
│   ├── iam-irsa/                   ← IAM Role + OIDC trust policy (real EKS)
│   │   ├── versions.tf
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf              # Outputs: role ARN, velero install command
│   └── iam-user/                   ← IAM User + Access Key (staging/LocalStack only)
│       ├── versions.tf
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf              # Outputs: access_key_id, secret_access_key
└── environments/                   ← One directory per environment
    ├── staging/                    ← Minikube + LocalStack (local development)
    │   ├── versions.tf             # No remote backend — local state, gitignored
    │   ├── providers.tf            # Provider pointing to localhost:4566
    │   ├── main.tf                 # Calls backup-storage + iam-user modules
    │   ├── variables.tf
    │   └── outputs.tf
    └── prod/                       ← Production on real AWS EKS
        ├── versions.tf             # S3 remote backend: prod/terraform.tfstate
        ├── providers.tf            # AWS provider with environment credentials
        ├── main.tf                 # Calls backup-storage + iam-irsa modules
        ├── variables.tf
        ├── outputs.tf
        └── terraform.tfvars.example
```

This mirrors the Kubernetes overlay pattern:

| Kubernetes | Terraform |
|---|---|
| `k8s/apps/base/` | `terraform/modules/` |
| `k8s/apps/overlays/staging/` | `terraform/environments/staging/` |
| `k8s/apps/overlays/prod/` | `terraform/environments/prod/` |

### Why separate `versions.tf`, `providers.tf`, and `main.tf`?

- **`versions.tf`** — the `terraform {}` block: minimum version, required provider, and `backend`. Static, almost never changes.
- **`providers.tf`** — the `provider {}` block only. Isolates provider configuration (endpoints, credentials strategy) from resource logic.
- **`main.tf`** — only module calls. Reading it makes immediately clear what the environment creates.

---

## Environment differences

| | `staging` | `prod` |
|---|---|---|
| Target | LocalStack at localhost:4566 | Real AWS EKS |
| Authentication | `test`/`test` (hardcoded) | AWS environment credentials |
| IAM strategy | IAM User + Access Key | IRSA (IAM Role + EKS OIDC) |
| State backend | Local file (gitignored) | S3 remote (`prod/terraform.tfstate`) |
| Backup retention | 30 days | 90 days |
| Secret recovery window | 0 days (immediate) | 30 days |

---

## Modules

### `backup-storage`

Creates the same two resources in both environments — only values differ:

- **S3 bucket** with versioning, AES-256 encryption, full public access block, and lifecycle expiry
- **Secrets Manager secret** — empty slot until `make backup-sealing-key` writes the controller RSA key into it

### `iam-irsa`

Used in **prod** only. Creates an IAM Role with a trust policy scoped to exactly the Velero ServiceAccount in the `velero` namespace on the specific EKS cluster. No static credentials generated.

### `iam-user`

Used in **staging** only. Creates an IAM User + Access Key because LocalStack has no real OIDC provider. Credentials are written to `credentials-velero` (gitignored) and passed to `velero install --secret-file`.

---

## End-to-end connection diagram

```
┌──────────────────────────────────────────────────────────┐
│  terraform/environments/staging                          │
│  (LocalStack at localhost:4566)                          │
│                                                          │
│  aws_s3_bucket  "openpanel-velero-backups"               │
│  aws_secretsmanager_secret  "devops-cluster/ss-key"      │
│  aws_iam_user   "velero-backup-user"  + access_key       │
└─────────────────────┬────────────────────────────────────┘
                      │
          ┌───────────┴──────────────────────────┐
          │                                      │
          ▼                                      ▼
  BackupStorageLocation                   make backup-sealing-key
  (staging patch)                         │
  bucket: openpanel-velero-backups        └─► aws secretsmanager put-secret-value
  s3Url:  http://192.168.49.1:4566              --endpoint-url http://localhost:4566
  ← Velero writes cluster backups here         --secret-id devops-cluster/ss-key

  credentials-velero                      make restore-sealing-key
  (from terraform output                  │
   velero_secret_access_key)              └─► aws secretsmanager get-secret-value
  ← passed to velero install                    → kubectl apply (reimport RSA key)
    --secret-file ./credentials-velero           → controller restart


┌──────────────────────────────────────────────────────────┐
│  terraform/environments/prod                             │
│  (Real AWS)                                              │
│                                                          │
│  aws_s3_bucket  "openpanel-velero-backups-prod"          │
│  aws_secretsmanager_secret  "devops-cluster-prod/ss-key" │
│  aws_iam_role   "velero-openpanel-prod"  (IRSA)          │
└─────────────────────┬────────────────────────────────────┘
                      │
          ┌───────────┴──────────────────────────┐
          │                                      │
          ▼                                      ▼
  BackupStorageLocation                   make backup-sealing-key
  (prod patch)                            │
  bucket: openpanel-velero-backups-prod   └─► aws secretsmanager put-secret-value
  region: us-east-1                             --secret-id devops-cluster-prod/ss-key
  ← no s3Url, no credentials file
    Velero assumes IAM Role via IRSA       velero install
    automatically                          --sa-annotations \
                                             iam.amazonaws.com/role=<role_arn>
                                           ← role_arn from:
                                             terraform output velero_role_arn
```

---

## Resource diagram

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  make terraform-infra ENV=staging                                            ║
║  Terraform → LocalStack (localhost:4566)                                     ║
╚══════════════════╤═══════════════════════════════════════════════════════════╝
                   │ creates
       ┌───────────┼───────────────────────────┐
       │           │                           │
       ▼           ▼                           ▼
┌─────────────┐  ┌──────────────────────┐  ┌──────────────────────────────┐
│  S3 Bucket  │  │   Secrets Manager    │  │         IAM User             │
│             │  │                      │  │                              │
│ openpanel-  │  │ devops-cluster/      │  │  velero-backup-user          │
│ velero-     │  │ sealed-secrets-      │  │         │                    │
│ backups     │  │ master-key           │  │         ├── velero-s3-policy │
│             │  │                      │  │         │   (GetObject,      │
│ • versioning│  │ (empty slot —        │  │         │    PutObject,      │
│   Enabled   │  │  filled later by     │  │         │    DeleteObject,   │
│ • AES-256   │  │  make backup-        │  │         │    ListBucket)     │
│   encrypted │  │  sealing-key)        │  │         │                    │
│ • public    │  │                      │  │         └── Access Key       │
│   access    │  └──────────┬───────────┘  │             LKIAQ...        │
│   blocked   │             │              └──────────────┬───────────────┘
│ • lifecycle │             │                             │
│   disabled  │             │                             │ written to
│   (staging) │             │                    ┌────────▼──────────────┐
└──────┬──────┘             │                    │   credentials-velero  │
       │                    │                    │                       │
       │ bucket_arn         │                    │ terraform/environ-    │
       │ referenced by      │                    │ ments/staging/        │
       │                    │                    │ credentials-velero    │
       ▼                    │                    │                       │
┌─────────────────────┐     │                    │ [default]             │
│ BackupStorageLocation│     │                    │ aws_access_key_id    │
│ (Velero CRD)        │     │                    │ aws_secret_access_key │
│                     │     │                    └────────┬──────────────┘
│ bucket: openpanel-  │     │                             │ passed to
│   velero-backups    │     │                             ▼
│ s3Url: http://      │     │                    ┌────────────────────────┐
│   192.168.49.1:4566 │     │                    │  velero install        │
│                     │     │                    │  --secret-file         │
│ Velero writes       │     │                    │  credentials-velero    │
│ backups here ───────┼─────┼────────────────────┼──► K8s Secret created  │
│ on schedule         │     │                    │    in velero namespace  │
└─────────────────────┘     │                    └────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
   ┌──────────────────────┐    ┌────────────────────────┐
   │  make backup-        │    │  make restore-         │
   │  sealing-key         │    │  sealing-key           │
   │                      │    │                        │
   │  reads RSA key from  │    │  reads RSA key from    │
   │  running Sealed      │    │  Secrets Manager →     │
   │  Secrets controller  │    │  kubectl apply →       │
   │  → writes into       │    │  controller restart    │
   │  Secrets Manager     │    │  (cluster recovery)    │
   └──────────────────────┘    └────────────────────────┘


╔══════════════════════════════════════════════════════════════════════════════╗
║  make terraform-infra ENV=prod                                               ║
║  Terraform → Real AWS                                                        ║
╚══════════════════╤═══════════════════════════════════════════════════════════╝
                   │ creates
       ┌───────────┼───────────────────────────┐
       │           │                           │
       ▼           ▼                           ▼
┌─────────────┐  ┌──────────────────────┐  ┌──────────────────────────────┐
│  S3 Bucket  │  │   Secrets Manager    │  │         IAM Role (IRSA)      │
│             │  │                      │  │                              │
│ openpanel-  │  │ devops-cluster-prod/ │  │  velero-openpanel-prod       │
│ velero-     │  │ sealed-secrets-      │  │                              │
│ backups-    │  │ master-key           │  │  Trust policy scoped to:     │
│ prod        │  │                      │  │  • velero ServiceAccount     │
│             │  │                      │  │  • velero namespace          │
│ • versioning│  │                      │  │  • this EKS cluster OIDC     │
│ • AES-256   │  │                      │  │                              │
│ • public    │  │                      │  │  No static credentials —     │
│   blocked   │  │                      │  │  EKS injects temp tokens     │
│ • 90-day    │  │                      │  │  automatically via OIDC      │
│   lifecycle │  │                      │  │                              │
└─────────────┘  └──────────────────────┘  │  role_arn → velero install  │
                                           │  --sa-annotations            │
                                           │  iam.amazonaws.com/role=arn  │
                                           └──────────────────────────────┘

  NOTE: IRSA cannot be used for staging — Minikube has no OIDC provider and
  LocalStack community does not support sts:AssumeRoleWithWebIdentity.
  IAM User + static key is the only option for local development.
```

---

## Why IRSA is not used for staging

IRSA (IAM Roles for Service Accounts) is the production IAM strategy — it requires an EKS OIDC provider to issue and validate the token that lets a Kubernetes ServiceAccount assume an IAM Role.

Staging uses Minikube + LocalStack, which makes IRSA impossible for two reasons:

1. **Minikube has no OIDC provider.** EKS automatically exposes one per cluster. Minikube does not. Setting one up manually is complex, fragile, and adds no real value in a local environment.
2. **LocalStack community does not support `sts:AssumeRoleWithWebIdentity`.** This is the STS call that exchanges the ServiceAccount token for temporary AWS credentials. It is a Pro-only feature in LocalStack.

Because of this, staging uses an **IAM User + static Access Key** instead. The key is written to `terraform/environments/staging/credentials-velero` and passed to `velero install --secret-file`. This is acceptable because the credentials only grant access to a local Docker container with no connection to real AWS.

| | Staging | Prod |
|---|---|---|
| IAM strategy | IAM User + static Access Key | IRSA (IAM Role + EKS OIDC) |
| Credentials file | `credentials-velero` written to disk | No file — EKS injects temp tokens |
| Static secrets | Yes (gitignored, LocalStack only) | No |
| `sts:AssumeRoleWithWebIdentity` | Not supported (LocalStack community) | Fully supported (real AWS STS) |

---

## Resources created

### Staging

| Resource | Type | Name | Module |
|---|---|---|---|
| S3 bucket | `aws_s3_bucket` | `openpanel-velero-backups` | `backup-storage` |
| S3 versioning | `aws_s3_bucket_versioning` | on above bucket | `backup-storage` |
| S3 encryption | `aws_s3_bucket_server_side_encryption_configuration` | AES-256 on above bucket | `backup-storage` |
| S3 public access block | `aws_s3_bucket_public_access_block` | all 4 rules blocked | `backup-storage` |
| Secrets Manager secret | `aws_secretsmanager_secret` | `devops-cluster/sealed-secrets-master-key` | `backup-storage` |
| IAM user | `aws_iam_user` | `velero-backup-user` | `iam-user` |
| IAM access key | `aws_iam_access_key` | for `velero-backup-user` | `iam-user` |
| IAM policy | `aws_iam_policy` | `velero-s3-policy` | `iam-user` |
| IAM policy attachment | `aws_iam_user_policy_attachment` | policy → user | `iam-user` |

**State file:** `terraform/environments/staging/terraform.tfstate` — local file, gitignored. Ephemeral: LocalStack resets when Docker stops; `terraform apply` recreates everything in seconds.

### Prod

| Resource | Type | Name | Module |
|---|---|---|---|
| S3 bucket | `aws_s3_bucket` | `openpanel-velero-backups-prod` | `backup-storage` |
| S3 versioning | `aws_s3_bucket_versioning` | on above bucket | `backup-storage` |
| S3 encryption | `aws_s3_bucket_server_side_encryption_configuration` | AES-256 on above bucket | `backup-storage` |
| S3 public access block | `aws_s3_bucket_public_access_block` | all 4 rules blocked | `backup-storage` |
| S3 lifecycle rule | `aws_s3_bucket_lifecycle_configuration` | 90-day expiry | `backup-storage` |
| Secrets Manager secret | `aws_secretsmanager_secret` | `devops-cluster-prod/sealed-secrets-master-key` | `backup-storage` |
| IAM role | `aws_iam_role` | `velero-openpanel-prod` | `iam-irsa` |
| IAM role policy | `aws_iam_role_policy` | S3 permissions on above role | `iam-irsa` |

**State file:** `s3://openpanel-terraform-state/prod/terraform.tfstate` — remote, encrypted, DynamoDB-locked.

---

## Resources created and how to verify

This section explains what each resource is for, who uses it, and the exact commands to confirm it was created correctly.

> All staging commands use `--endpoint-url http://localhost:4566` to point at LocalStack instead of real AWS.

---

### S3 bucket — `openpanel-velero-backups`

**Why it exists:** Velero needs a place outside the cluster to store backup archives. If the cluster is destroyed, the backups must survive — so they live in S3, not inside Kubernetes.

**Who uses it:** The Velero controller running in the `velero` namespace. It reads the bucket name from the `BackupStorageLocation` CRD (`k8s/infrastructure/overlays/staging/velero/backup-location-patch.yaml`). Every scheduled or manual backup writes a `.tar.gz` archive here.

**How to verify:**

```bash
# Bucket exists
aws --endpoint-url http://localhost:4566 s3 ls

# Versioning enabled — protects against accidental overwrites
aws --endpoint-url http://localhost:4566 s3api get-bucket-versioning \
  --bucket openpanel-velero-backups

# AES-256 server-side encryption on all objects
aws --endpoint-url http://localhost:4566 s3api get-bucket-encryption \
  --bucket openpanel-velero-backups

# Public access fully blocked — bucket is never internet-accessible
aws --endpoint-url http://localhost:4566 s3api get-public-access-block \
  --bucket openpanel-velero-backups

# 30-day lifecycle expiry rule (prod only — disabled in staging/LocalStack)
aws --endpoint-url http://localhost:4566 s3api get-bucket-lifecycle-configuration \
  --bucket openpanel-velero-backups
```

---

### Secrets Manager secret — `devops-cluster/sealed-secrets-master-key`

**Why it exists:** The Sealed Secrets controller generates an RSA key pair on first boot and stores it as a Kubernetes Secret. All SealedSecret resources in Git are encrypted with that key. If the cluster is deleted and rebuilt, the controller generates a *new* key — meaning all existing SealedSecrets in Git become unreadable. Backing up the original RSA key to Secrets Manager means a rebuilt cluster can import it and decrypt everything without re-sealing.

**Who uses it:**
- `make backup-sealing-key` — exports the key from the running controller and writes it into this slot
- `make restore-sealing-key` — reads it back and imports it into a fresh cluster before ArgoCD starts syncing

**How to verify:**

```bash
# Secret slot exists
aws --endpoint-url http://localhost:4566 secretsmanager list-secrets

# Slot metadata — the slot is intentionally empty until make backup-sealing-key runs
aws --endpoint-url http://localhost:4566 secretsmanager describe-secret \
  --secret-id devops-cluster/sealed-secrets-master-key
```

---

### IAM user + access key — `velero-backup-user` (staging only)

**Why it exists:** Velero needs AWS credentials to read and write the S3 bucket. In prod, Velero uses IRSA (IAM Role for Service Accounts) — the EKS node injects temporary credentials automatically, no static keys needed. In staging, LocalStack has no OIDC provider, so a classic IAM User with an Access Key is the only option.

**Who uses it:** The Velero controller. The credentials are written to `credentials-velero` in the project root, which is passed to `velero install --secret-file ./credentials-velero`. Velero mounts it as a Kubernetes Secret and uses it for every S3 call.

**How to verify:**

```bash
# User exists
aws --endpoint-url http://localhost:4566 iam list-users

# Active access key was generated for the user
aws --endpoint-url http://localhost:4566 iam list-access-keys \
  --user-name velero-backup-user

# S3 policy is attached to the user
aws --endpoint-url http://localhost:4566 iam list-attached-user-policies \
  --user-name velero-backup-user

# Full policy document — confirms minimal S3 permissions (GetObject, PutObject, DeleteObject, ListBucket)
aws --endpoint-url http://localhost:4566 iam get-policy-version \
  --policy-arn $(aws --endpoint-url http://localhost:4566 iam list-attached-user-policies \
      --user-name velero-backup-user --query 'AttachedPolicies[0].PolicyArn' --output text) \
  --version-id v1
```

---

### `credentials-velero` file (staging only)

**What it is:** An AWS credentials file in the standard AWS CLI format containing the IAM access key Terraform generated for `velero-backup-user`.

**Where it is stored:** `terraform/environments/staging/credentials-velero` — co-located with the staging state that produced it. Gitignored, never committed.

**How it is created:** The `terraform-infra` Makefile target reads the Terraform outputs after `apply` and writes the file automatically:

```bash
printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
  "$(terraform output -raw velero_access_key_id)" \
  "$(terraform output -raw velero_secret_access_key)" \
  > terraform/environments/staging/credentials-velero
```

**How it is used:** Passed to `velero install` during cluster setup:

```bash
velero install --secret-file terraform/environments/staging/credentials-velero ...
```

Velero reads the file once at install time, creates a Kubernetes Secret from it in the `velero` namespace, and then uses those credentials for every S3 call against LocalStack. After install the file is no longer needed — the credentials live inside the cluster.

**How to verify:**

```bash
cat terraform/environments/staging/credentials-velero
```

Expected output:
```ini
[default]
aws_access_key_id     = LKIA...
aws_secret_access_key = ...
```

**Prod:** This file is never created for prod. Prod uses **IRSA (IAM Role for Service Accounts)** — the EKS node automatically injects short-lived credentials into the Velero pod via the OIDC provider. No static keys are generated, no file is written, no secret needs to be managed. The IAM role ARN is passed as a pod annotation instead:

```bash
velero install \
  --sa-annotations iam.amazonaws.com/role=$(terraform output -raw velero_role_arn)
```

---

### Terraform state — what Terraform itself tracks

```bash
cd terraform/environments/staging

# All resources managed by this environment
terraform state list

# Inspect one resource in full detail
terraform state show module.backup_storage.aws_s3_bucket.velero_backups
terraform state show module.backup_storage.aws_secretsmanager_secret.sealed_secrets_key
terraform state show module.velero_iam.aws_iam_user.velero
terraform state show module.velero_iam.aws_iam_access_key.velero

# All output values (bucket name, ARNs, access key ID)
terraform output
```

---

## How to run

### Staging (Minikube + LocalStack)

```bash
make terraform-infra ENV=staging
```

This single command: checks prerequisites (terraform, aws CLI, docker), starts LocalStack automatically if not running, runs `terraform init` + `terraform plan`, shows the plan, asks for confirmation, applies, and writes `credentials-velero`.

### Prod (real AWS EKS)

Bootstrap the remote state backend once per AWS account (see `environments/prod/versions.tf` for the full AWS CLI commands).

```bash
cp terraform/environments/prod/terraform.tfvars.example \
   terraform/environments/prod/terraform.tfvars
# Fill in eks_cluster_name, bucket_name, aws_region

cd terraform/environments/prod
terraform init
terraform apply
terraform output velero_install_command   # ready-to-run velero install with IRSA ARN
```

---

## State management

| Environment | State location | Why |
|---|---|---|
| `staging` | `environments/staging/terraform.tfstate` (local, gitignored) | Ephemeral — LocalStack resets when Docker stops; `apply` recreates in seconds |
| `prod` | S3 `openpanel-terraform-state/prod/terraform.tfstate` | Durable, encrypted, locked via DynamoDB |

> `terraform.tfstate` contains sensitive values (access keys, ARNs) in plaintext. Remote state on S3 with `encrypt = true` is the only safe option for prod. The state bucket is created manually with the AWS CLI — Terraform cannot manage its own state bucket.
