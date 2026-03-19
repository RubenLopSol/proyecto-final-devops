# Terraform — Infraestructura de Backup en AWS

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Propósito

El módulo Terraform provisiona la infraestructura de almacenamiento necesaria para que Velero pueda realizar backups en AWS S3:

- **Bucket S3** con versionado, cifrado AES-256, bloqueo de acceso público y política de retención de 30 días.
- **IAM Role + IRSA** (IAM Roles for Service Accounts) para que el pod de Velero en EKS asuma el rol sin necesidad de credenciales estáticas.

> Este módulo es una **demostración de IaC** (Infrastructure as Code). En el entorno local del proyecto se usa MinIO como almacenamiento S3-compatible. El módulo Terraform está pensado para un despliegue real en AWS.

---

## Estructura

```
terraform/
├── main.tf          # Bucket S3 (versionado, cifrado, lifecycle, acceso público bloqueado)
├── iam.tf           # IAM Role con trust policy IRSA + IAM Policy mínima para Velero
├── variables.tf     # Variables configurables
├── outputs.tf       # Outputs: bucket ARN, role ARN, comando velero install
└── localstack/      # Versión adaptada para validación local con LocalStack
    ├── main.tf      # Mismo S3 apuntando a http://localhost:4566
    ├── iam.tf       # IAM User + Access Key (sin IRSA, LocalStack no emula EKS OIDC)
    ├── variables.tf
    └── outputs.tf
```

---

## Variables

| Variable | Descripción | Valor por defecto |
|---|---|---|
| `bucket_name` | Nombre del bucket S3 | `openpanel-velero-backups` |
| `aws_region` | Región de AWS | `us-east-1` |
| `retention_days` | Días de retención de backups | `30` |
| `velero_namespace` | Namespace de Velero en EKS | `velero` |
| `velero_service_account` | ServiceAccount de Velero | `velero` |
| `eks_cluster_name` | Nombre del clúster EKS | `openpanel-cluster` |

---

## Uso en AWS real

```bash
cd terraform/

# Inicializar
terraform init

# Planificar
terraform plan \
  -var="eks_cluster_name=mi-cluster" \
  -var="aws_region=eu-west-1"

# Aplicar
terraform apply \
  -var="eks_cluster_name=mi-cluster" \
  -var="aws_region=eu-west-1"

# Ver outputs
terraform output
terraform output -raw velero_install_command
```

El output `velero_install_command` genera el comando completo para instalar Velero con IRSA:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket openpanel-velero-backups \
  --no-secret \
  --sa-annotations iam.amazonaws.com/role=arn:aws:iam::ACCOUNT_ID:role/velero-irsa-role \
  --backup-location-config region=eu-west-1 \
  --use-volume-snapshots=false
```

---

## Validación local con LocalStack

[LocalStack](https://localstack.cloud/) emula los servicios de AWS en local (puerto 4566). Permite validar el módulo Terraform sin credenciales reales ni coste alguno.

### Requisitos

- Docker en ejecución
- LocalStack instalado: `pip install localstack` o imagen Docker `localstack/localstack`
- Terraform >= 1.5.0

### Arrancar LocalStack

```bash
localstack start -d
# O con Docker:
docker run -d -p 4566:4566 localstack/localstack
```

### Aplicar el módulo LocalStack

```bash
cd terraform/localstack/

terraform init
terraform plan
terraform apply
```

Recursos creados (7 en total):

| Recurso | Nombre |
|---|---|
| `aws_s3_bucket` | `openpanel-velero-backups` |
| `aws_s3_bucket_versioning` | Habilitado |
| `aws_s3_bucket_server_side_encryption_configuration` | AES-256 |
| `aws_s3_bucket_public_access_block` | Todo bloqueado |
| `aws_s3_bucket_lifecycle_configuration` | Expiración a 30 días |
| `aws_iam_user` | `velero-backup-user` |
| `aws_iam_access_key` | Credenciales para Velero |

### Verificar el resultado

```bash
# Ver outputs (las credenciales generadas)
terraform output
terraform output -raw velero_secret_access_key

# Verificar el bucket en LocalStack via AWS CLI
aws --endpoint-url=http://localhost:4566 s3 ls
aws --endpoint-url=http://localhost:4566 s3api get-bucket-versioning \
  --bucket openpanel-velero-backups

# Verificar el usuario IAM
aws --endpoint-url=http://localhost:4566 iam list-users
```

### Destruir los recursos

```bash
terraform destroy
localstack stop
```

---

## Diferencias entre módulo AWS y módulo LocalStack

| Aspecto | `terraform/` (AWS) | `terraform/localstack/` |
|---|---|---|
| Autenticación | Credenciales reales de AWS | `access_key = "test"` (fijo) |
| IAM | Role + IRSA (para EKS) | User + Access Key (estático) |
| Endpoints | AWS por defecto | `http://localhost:4566` |
| `s3_use_path_style` | No necesario | Obligatorio (evita DNS virtual-hosted) |
| Persistencia | Permanente en AWS | Efímera (se pierde al parar LocalStack) |
| Coste | Según uso (~5-10 €/mes para este volumen) | Gratuito |

---

## Notas de implementación

- **`filter {}`** en la lifecycle rule es obligatorio en el provider AWS v5 aunque no se aplique ningún filtro. Sin él, Terraform emite un error de validación.
- **`s3_use_path_style = true`** es necesario en LocalStack porque el provider AWS v5 usa por defecto URLs virtual-hosted (`bucket.localhost`) que LocalStack no resuelve correctamente.
- En un entorno EKS real, IRSA es preferible a las Access Keys estáticas porque no requiere rotar credenciales y sigue el principio de mínimo privilegio a nivel de pod.
