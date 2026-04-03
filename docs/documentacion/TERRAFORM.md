# Terraform — Infraestructura de Backup en AWS

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Propósito

Terraform provisiona la infraestructura de almacenamiento externa que el clúster necesita para dos cosas:

- **Bucket S3** — donde Velero escribe los backups diarios de Kubernetes. Configurado con versionado, cifrado AES-256, bloqueo de acceso público y ciclo de vida automático.
- **Slot en Secrets Manager** — guarda la clave RSA del controller de Sealed Secrets. Si el clúster se destruye y se recrea, esta clave permite descifrar los SealedSecrets existentes sin tener que volverlos a sellar.

Terraform crea las ranuras vacías. El contenido real lo escriben después los targets del Makefile: `make backup-sealing-key` y Velero respectivamente.

---

## Estructura

```
terraform/
├── modules/                        ← Lógica reutilizable (sin valores de entorno)
│   ├── backup-storage/             ← Bucket S3 + slot en Secrets Manager
│   │   ├── versions.tf             # Requisitos de provider
│   │   ├── main.tf                 # Recursos
│   │   ├── variables.tf            # Inputs
│   │   └── outputs.tf              # Outputs: bucket ARN, secret ARN
│   ├── iam-irsa/                   ← IAM Role + OIDC trust policy (EKS real)
│   │   ├── versions.tf
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf              # Outputs: role ARN, velero install command
│   └── iam-user/                   ← IAM User + Access Key (solo LocalStack)
│       ├── versions.tf
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf              # Outputs: access_key_id, secret_access_key
└── environments/                   ← Un directorio por entorno
    ├── localstack/                 ← Desarrollo local (Docker, sin AWS real)
    │   ├── versions.tf             # Sin backend (estado local, gitignored)
    │   ├── providers.tf            # Provider apuntando a localhost:4566
    │   ├── main.tf                 # Llama a backup-storage + iam-user
    │   ├── variables.tf
    │   └── outputs.tf
    ├── staging/                    ← Staging en AWS real
    │   ├── versions.tf             # Backend S3: staging/terraform.tfstate
    │   ├── providers.tf            # Provider AWS con credenciales de entorno
    │   ├── main.tf                 # Llama a backup-storage + iam-irsa
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── terraform.tfvars.example
    └── prod/                       ← Producción en AWS real
        ├── versions.tf             # Backend S3: prod/terraform.tfstate
        ├── providers.tf            # Provider AWS con credenciales de entorno
        ├── main.tf                 # Llama a backup-storage + iam-irsa
        ├── variables.tf
        ├── outputs.tf
        └── terraform.tfvars.example
```

Este patrón refleja exactamente la estructura de Kubernetes:

| Kubernetes | Terraform |
|---|---|
| `k8s/apps/base/` | `terraform/modules/` |
| `k8s/apps/overlays/staging/` | `terraform/environments/staging/` |
| `k8s/apps/overlays/prod/` | `terraform/environments/prod/` |

### ¿Por qué separar `versions.tf`, `providers.tf` y `main.tf`?

- **`versions.tf`** — declara `terraform {}`: versión mínima, provider requerido y bloque `backend`. Es estático y casi nunca cambia.
- **`providers.tf`** — contiene solo el bloque `provider {}`. Permite cambiar la configuración del provider (región, assume_role para CI) sin tocar la lógica de módulos.
- **`main.tf`** — solo llamadas a módulos. Al leerlo queda claro qué crea el entorno, sin ruido de boilerplate.

---

## Diferencias entre entornos

| | `localstack` | `staging` | `prod` |
|---|---|---|---|
| Target | LocalStack en localhost:4566 | AWS real | AWS real |
| Autenticación | `test`/`test` (fijo) | Credenciales de entorno | Credenciales de entorno |
| IAM | IAM User + Access Key | IRSA (Role + OIDC) | IRSA (Role + OIDC) |
| Estado | Local (gitignored) | S3 remoto (`staging/`) | S3 remoto (`prod/`) |
| Retención backups | 30 días | 30 días | 90 días |
| Ventana de recuperación secret | 0 días (inmediato) | 7 días | 30 días |

---

## Módulos

### `backup-storage`

Crea los mismos dos recursos en todos los entornos:

- **Bucket S3** con versionado, AES-256, bloqueo público total y regla de ciclo de vida
- **Secret en Secrets Manager** (`devops-cluster/sealed-secrets-master-key`) — ranura vacía que se rellena con `make backup-sealing-key`

### `iam-irsa`

Usado en **staging** y **prod**. Crea un IAM Role con una trust policy que solo permite al ServiceAccount de Velero en el namespace `velero` del clúster EKS específico asumir el rol. No se generan credenciales estáticas.

### `iam-user`

Usado exclusivamente en **localstack**. Crea un IAM User + Access Key porque LocalStack no tiene OIDC provider real. Las credenciales se escriben en `credentials-velero` (gitignored) y se pasan a `velero install --secret-file`.

---

## Variables por entorno

### `localstack` y `staging`

| Variable | `localstack` | `staging` |
|---|---|---|
| `bucket_name` | `openpanel-velero-backups` | `openpanel-velero-backups-staging` |
| `retention_days` | `30` | `30` |
| `eks_cluster_name` | — (no aplica) | `openpanel-staging` |

### `prod`

| Variable | Valor por defecto |
|---|---|
| `bucket_name` | `openpanel-velero-backups-prod` |
| `retention_days` | `90` |
| `eks_cluster_name` | `openpanel-prod` |
| `sealed_secrets_secret_name` | `devops-cluster-prod/sealed-secrets-master-key` |

---

## Uso

### LocalStack (desarrollo local)

Requiere LocalStack en ejecución:

```bash
docker run -d -p 4566:4566 localstack/localstack
```

```bash
cd terraform/environments/localstack
terraform init
terraform apply
```

Obtener las credenciales para `credentials-velero`:

```bash
terraform output velero_access_key_id
terraform output -raw velero_secret_access_key
```

Verificar los recursos creados:

```bash
# Verificar el bucket en LocalStack
aws --endpoint-url=http://localhost:4566 s3 ls
aws --endpoint-url=http://localhost:4566 s3api get-bucket-versioning \
  --bucket openpanel-velero-backups

# Verificar el usuario IAM
aws --endpoint-url=http://localhost:4566 iam list-users

# Verificar el secret en Secrets Manager
aws --endpoint-url=http://localhost:4566 secretsmanager list-secrets
```

![Terraform — Apply con LocalStack mostrando infraestructura estable y outputs](../screenshots/terraform-apply-localstack.png)

### Staging / Prod (AWS real)

El backend S3 debe existir antes de ejecutar `terraform init`. Crearlo una vez con la AWS CLI:

```bash
# Crear el bucket de estado
aws s3api create-bucket \
  --bucket openpanel-terraform-state \
  --region us-east-1
aws s3api put-bucket-versioning \
  --bucket openpanel-terraform-state \
  --versioning-configuration Status=Enabled

# Crear la tabla DynamoDB para bloqueo de estado
aws dynamodb create-table \
  --table-name openpanel-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Después:

```bash
cp terraform/environments/staging/terraform.tfvars.example \
   terraform/environments/staging/terraform.tfvars
# Editar terraform.tfvars con los valores reales

cd terraform/environments/staging
terraform init
terraform apply
```

El output `velero_install_command` genera el comando completo con el ARN del rol IRSA ya incluido:

```bash
terraform output velero_install_command
```

---

## Recursos creados por entorno

| Recurso | `localstack` | `staging` | `prod` |
|---|---|---|---|
| `aws_s3_bucket` | `openpanel-velero-backups` | `openpanel-velero-backups-staging` | `openpanel-velero-backups-prod` |
| `aws_s3_bucket_versioning` | Habilitado | Habilitado | Habilitado |
| `aws_s3_bucket_server_side_encryption_configuration` | AES-256 | AES-256 | AES-256 |
| `aws_s3_bucket_public_access_block` | Todo bloqueado | Todo bloqueado | Todo bloqueado |
| `aws_s3_bucket_lifecycle_configuration` | 30 días | 30 días | 90 días |
| `aws_secretsmanager_secret` | `devops-cluster/sealed-secrets-master-key` | mismo | `devops-cluster-prod/…` |
| `aws_iam_user` | `velero-backup-user` | — | — |
| `aws_iam_access_key` | Credenciales Velero | — | — |
| `aws_iam_role` | — | `velero-openpanel-staging` | `velero-openpanel-prod` |
| `aws_iam_policy` | `velero-s3-policy` | `velero-s3-openpanel-staging` | `velero-s3-openpanel-prod` |

---

## Estado de Terraform

### LocalStack

El estado reside en `environments/localstack/terraform.tfstate` (local, gitignored). Es intencional — este entorno es efímero, corre contra un contenedor Docker y si se resetea basta con ejecutar `terraform apply` de nuevo.

### Staging y Prod

El estado se guarda en el bucket S3 `openpanel-terraform-state` con claves separadas por entorno:

- `staging/terraform.tfstate`
- `prod/terraform.tfstate`

El estado en S3 está cifrado (`encrypt = true`) y el acceso está controlado por IAM. La tabla DynamoDB `openpanel-terraform-locks` previene aplicaciones concurrentes.

> **Por qué el bucket de estado no lo gestiona Terraform**: si el bucket de estado fallara al crearse, no habría dónde escribir el estado de ese fallo. El bucket de bootstrap se crea una vez con la AWS CLI y Terraform nunca lo toca.

---

## Notas de implementación

- **`filter {}`** en la lifecycle rule es obligatorio en el provider AWS v5 aunque no se aplique ningún filtro. Sin él, Terraform emite un error de validación.
- **`s3_use_path_style = true`** es necesario en LocalStack porque el provider AWS v5 usa por defecto URLs virtual-hosted (`bucket.localhost`) que LocalStack no resuelve correctamente.
- **IRSA vs Access Key**: en EKS real, IRSA no genera credenciales estáticas — el pod de Velero asume el rol directamente vía OIDC. Las Access Keys de LocalStack son el equivalente funcional para entornos sin OIDC.
- **`terraform.tfvars` está en `.gitignore`**: los valores reales de producción (nombres de clúster, región, etc.) nunca se commitean. Usar `terraform.tfvars.example` como plantilla.
