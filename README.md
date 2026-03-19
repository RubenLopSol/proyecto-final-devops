# OpenPanel DevOps Project

Pipeline DevOps completo para [OpenPanel](https://github.com/Openpanel-dev/openpanel) desplegado sobre Kubernetes con GitOps, observabilidad completa, Blue-Green deployment y backup automatizado.

**Autor:** Rubén López Solé

**Especialidad:** GitOps con ArgoCD

**Máster en DevOps & Cloud Computing — Marzo 2026**

---

## Stack

| Área | Herramienta |
|---|---|
| Orquestación | Kubernetes (Minikube) |
| GitOps / CD | ArgoCD |
| CI | GitHub Actions |
| Registry | GitHub Container Registry (GHCR) |
| Secrets | Sealed Secrets (Bitnami) |
| Métricas | Prometheus |
| Logs | Loki + Promtail |
| Trazas | Tempo |
| Dashboards | Grafana |
| Backup | Velero + MinIO |
| IaC | Terraform + LocalStack |
| Deployment | Blue-Green (API) |

---

## Estructura del Repositorio

```
proyecto_final/
├── openpanel/                  # Código fuente de OpenPanel (fork)
├── k8s/
│   ├── base/
│   │   ├── namespaces/         # Definición de namespaces
│   │   ├── openpanel/          # API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis
│   │   ├── observability/      # Prometheus, Grafana, Loki, Promtail, Tempo
│   │   └── backup/             # MinIO, Velero schedules
│   ├── overlays/
│   │   └── local/              # Overlay para Minikube (resource limits)
│   └── argocd/
│       ├── applications/       # ArgoCD Application manifests
│       ├── projects/           # ArgoCD Project
│       └── sealed-secrets/     # Secrets cifrados (Sealed Secrets)
├── .github/workflows/
│   ├── ci.yml                  # Pipeline CI: lint, build, scan, push
│   └── cd.yml                  # Pipeline CD: actualiza image tags en Git
├── scripts/
│   ├── setup-minikube.sh       # Arrancar el clúster
│   ├── install-argocd.sh       # Instalar ArgoCD
│   ├── blue-green-switch.sh    # Conmutación Blue-Green
│   └── backup-restore.sh       # Backup y restauración (Velero, PostgreSQL, Redis, ClickHouse)
├── terraform/
│   ├── main.tf                 # Bucket S3 + configuración (AWS real)
│   ├── iam.tf                  # IAM Role + IRSA para EKS (AWS real)
│   ├── variables.tf            # Variables del módulo
│   ├── outputs.tf              # Outputs (ARN, comando velero install)
│   └── localstack/             # Versión LocalStack para validación local
│       ├── main.tf             # Mismo S3, apuntando a localhost:4566
│       ├── iam.tf              # IAM User + Access Key (sin IRSA)
│       ├── variables.tf
│       └── outputs.tf
└── docs/
    ├── documentacion/          # Documentación técnica completa
    └── propuesta_proyecto/     # Propuesta del proyecto
```

---

## Quick Start

### Requisitos

- Docker
- Minikube v1.32+
- kubectl v1.28+
- helm v3+
- ArgoCD CLI
- kubeseal (Sealed Secrets CLI)
- velero CLI

### 1. Arrancar el clúster

```bash
./scripts/setup-minikube.sh
```

### 2. Instalar Sealed Secrets (antes que ArgoCD)

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n sealed-secrets --create-namespace
```

### 3. Aplicar Sealed Secrets

> **Importante:** Los secrets de este repositorio están cifrados con la clave del clúster original y **no funcionarán** en un clúster nuevo. Ver sección [Adaptar el proyecto](#adaptar-el-proyecto-para-un-nuevo-entorno).

```bash
kubectl apply -f k8s/argocd/sealed-secrets/
```

Esto despliega automáticamente todos los secrets necesarios:
- Credenciales de PostgreSQL, Redis, ClickHouse y la aplicación (`namespace: openpanel`)
- Credenciales de Grafana admin (`namespace: observability`)
- Credenciales de MinIO (`namespace: backup`)

### 4. Instalar ArgoCD

```bash
./scripts/install-argocd.sh
```

### 5. Desplegar con ArgoCD

```bash
kubectl apply -f k8s/argocd/projects/
kubectl apply -f k8s/argocd/applications/
```

### 6. Instalar Velero

```bash
# Crear el archivo de credenciales de MinIO (mismo usuario/password que el Sealed Secret)
cat > velero-credentials <<EOF
[default]
aws_access_key_id=minioadmin
aws_secret_access_key=minio-secret-2024
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000

kubectl apply -f k8s/base/backup/velero/schedule.yaml
```

### 7. Configurar DNS local

```bash
echo "$(minikube ip -p openpanel) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
  | sudo tee -a /etc/hosts
```

### Acceso a los servicios

| Servicio | URL |
|---|---|
| Dashboard | http://openpanel.local |
| API | http://api.openpanel.local |
| ArgoCD | https://argocd.local |
| Grafana | http://grafana.local |
| Prometheus | http://prometheus.local |

---

## Adaptar el Proyecto para un Nuevo Entorno

Para reutilizar este proyecto con tu propia cuenta de GitHub y tu propio clúster, es necesario actualizar las siguientes variables:

### 1. Usuario y repositorio de GitHub

El nombre de usuario está referenciado en las ArgoCD Applications y en los manifiestos de los deployments. Hay que actualizarlo en **8 archivos**:

| Archivo | Campo a cambiar | Valor actual |
|---|---|---|
| `k8s/argocd/applications/openpanel-app.yaml` | `spec.source.repoURL` | `https://github.com/RubenLopSol/proyecto_final.git` |
| `k8s/argocd/applications/observability-app.yaml` | `spec.source.repoURL` | `https://github.com/RubenLopSol/proyecto_final.git` |
| `k8s/argocd/applications/backup-app.yaml` | `spec.source.repoURL` | `https://github.com/RubenLopSol/proyecto_final.git` |
| `k8s/argocd/projects/openpanel-project.yaml` | `spec.sourceRepos` | `https://github.com/RubenLopSol/proyecto_final.git` |
| `k8s/base/openpanel/api-deployment-blue.yaml` | `image` | `ghcr.io/rubenlopsol/openpanel-api:...` |
| `k8s/base/openpanel/api-deployment-green.yaml` | `image` | `ghcr.io/rubenlopsol/openpanel-api:...` |
| `k8s/base/openpanel/start-deployment.yaml` | `image` | `ghcr.io/rubenlopsol/openpanel-start:...` |
| `k8s/base/openpanel/worker-deployment.yaml` | `image` | `ghcr.io/rubenlopsol/openpanel-worker:...` |

Sustitución rápida con `sed`:

```bash
# Reemplazar el usuario en todo el directorio k8s/
find k8s/ -name "*.yaml" -exec sed -i \
  's/RubenLopSol/<TU_USUARIO_GITHUB>/g; s/rubenlopsol/<tu_usuario_github_minusculas>/g' {} +
```

---

### 2. Sealed Secrets — Recrear todos los secrets

> **Los Sealed Secrets están cifrados con la clave pública del clúster original. No se pueden descifrar en ningún otro clúster.**

Cuando levantes un clúster nuevo, debes recrear cada SealedSecret cifrándolo con la clave de tu clúster.

#### Secrets que necesitas crear

| Secret | Namespace | Claves requeridas |
|---|---|---|
| `postgres-credentials` | `openpanel` | `postgres-user`, `postgres-password` |
| `redis-credentials` | `openpanel` | `redis-password` |
| `clickhouse-credentials` | `openpanel` | `clickhouse-user`, `clickhouse-password` |
| `openpanel-secrets` | `openpanel` | `secret` (JWT secret de la app) |
| `grafana-admin-credentials` | `observability` | `admin-user`, `admin-password` |

#### Ejemplo: crear un Sealed Secret

```bash
# 1. Crear el secret en local (sin aplicar)
kubectl create secret generic postgres-credentials \
  --from-literal=postgres-user=postgres \
  --from-literal=postgres-password=TU_PASSWORD_SEGURA \
  --namespace openpanel \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-namespace sealed-secrets \
  --format yaml > k8s/argocd/sealed-secrets/postgres-credentials.yaml

# 2. Repetir para cada secret de la tabla anterior
# 3. Commitear y pushear los nuevos SealedSecrets
git add k8s/argocd/sealed-secrets/
git commit -m "chore: recreate sealed secrets for new cluster"
git push
```

---

### 3. ConfigMap de la aplicación

Actualizar las URLs en `k8s/base/openpanel/configmap.yaml` si usas un dominio diferente a `openpanel.local`:

```yaml
data:
  NEXT_PUBLIC_API_URL: "http://api.TU_DOMINIO"
  NEXT_PUBLIC_DASHBOARD_URL: "http://TU_DOMINIO"
```

---

### 4. Credenciales de Velero / MinIO

Para el backup, Velero necesita credenciales de acceso a MinIO. Crear el archivo `velero-credentials` (no commitear):

```ini
[default]
aws_access_key_id=TU_MINIO_ACCESS_KEY
aws_secret_access_key=TU_MINIO_SECRET_KEY
```

Y usarlo al instalar Velero:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000
```

---

### Checklist de adaptación

- [ ] Sustituir `RubenLopSol` / `rubenlopsol` por tu usuario de GitHub en los 8 archivos
- [ ] Recrear todos los Sealed Secrets con la clave de tu nuevo clúster
- [ ] Actualizar las URLs en `configmap.yaml` si usas un dominio diferente
- [ ] Crear el archivo `velero-credentials` con tus credenciales de MinIO
- [ ] Hacer fork del repositorio y actualizar los `repoURL` de ArgoCD a tu fork

---

## Documentación

La documentación técnica completa está en [`docs/documentacion/`](docs/documentacion/):

| Documento | Contenido |
|---|---|
| [ARCHITECTURE.md](docs/documentacion/ARCHITECTURE.md) | Arquitectura del sistema, diagramas, namespaces |
| [SETUP.md](docs/documentacion/SETUP.md) | Instalación paso a paso del entorno completo |
| [GITOPS.md](docs/documentacion/GITOPS.md) | Flujo GitOps, ArgoCD, Kustomize |
| [CICD.md](docs/documentacion/CICD.md) | Pipeline CI/CD, jobs, estrategia de tags |
| [BLUE-GREEN.md](docs/documentacion/BLUE-GREEN.md) | Estrategia Blue-Green para la API |
| [OBSERVABILITY.md](docs/documentacion/OBSERVABILITY.md) | Prometheus, Grafana, Loki, Tempo, alertas |
| [BACKUP-RECOVERY.md](docs/documentacion/BACKUP-RECOVERY.md) | Velero + MinIO, schedules, restauración |
| [SECURITY.md](docs/documentacion/SECURITY.md) | Sealed Secrets, Network Policies, RBAC |
| [OPERATIONS.md](docs/documentacion/OPERATIONS.md) | Comandos de operación del sistema |
| [RUNBOOK.md](docs/documentacion/RUNBOOK.md) | Procedimientos para despliegues e incidentes |
| [TERRAFORM.md](docs/documentacion/TERRAFORM.md) | Módulo Terraform para S3+IAM en AWS; validación local con LocalStack |
