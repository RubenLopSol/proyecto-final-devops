# OpenPanel DevOps Project <!-- CI validated -->

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
| Métricas | Prometheus + AlertManager |
| Logs | Loki + Promtail |
| Trazas | Tempo |
| Dashboards | Grafana |
| Supply Chain | SBOM (Anchore) + Trivy |
| Backup | Velero + MinIO |
| IaC | Terraform + LocalStack |
| Deployment | Blue-Green (API) |

---

## Despliegue Automático

Para desplegar todo el proyecto desde cero con un solo comando:

```bash
make all GITHUB_USER=rubenlopsol GITHUB_TOKEN=gho_xxx
```

ArgoCD sincronizará la aplicación, la observabilidad y el backup automáticamente tras la instalación. Para ver todos los comandos disponibles:

```bash
make help
```

---

## Estructura del Repositorio

```
proyecto_final/
├── .github/workflows/
│   ├── ci-validate.yml          # CI-Lint-Test-Validate: valida manifiestos K8s, Dockerfiles y secretos en cada PR/push
│   ├── ci-build-publish.yml     # CI-Build-Publish: construye imágenes, genera SBOM, escanea con Trivy
│   └── cd-update-tags.yml       # CD-Update-GitOps-Manifests: actualiza image tags y crea release tag
│
├── .kube-linter.yaml            # Configuración de kube-linter (checks activos y excluidos)
├── .hadolint.yaml               # Configuración de hadolint (nivel mínimo de severidad)
│
├── openpanel/                   # Código fuente de OpenPanel (fork)
│
├── k8s/
│   ├── base/
│   │   ├── namespaces/          # Definición de namespaces
│   │   ├── openpanel/           # API (blue/green), Dashboard, Worker, PostgreSQL, ClickHouse, Redis
│   │   └── backup/              # MinIO, Velero schedules
│   ├── helm/
│   │   └── values/              # Values files para Helm charts
│   │       ├── kube-prometheus-stack.yaml  # Prometheus + Grafana + AlertManager + alertas
│   │       ├── argocd.yaml                 # ArgoCD Helm values
│   │       ├── loki.yaml                   # Agregación de logs
│   │       ├── promtail.yaml               # Recolección de logs
│   │       └── tempo.yaml                  # Distributed tracing
│   ├── overlays/
│   │   └── local/               # Overlay para Minikube (resource limits)
│   └── argocd/
│       ├── bootstrap-app.yaml   # App of Apps — raíz del patrón GitOps
│       ├── applications/        # ArgoCD Application manifests (Kustomize + Helm)
│       ├── projects/            # ArgoCD AppProject (permisos y scope)
│       └── sealed-secrets/      # Secrets cifrados (Sealed Secrets)
│
├── scripts/
│   ├── setup-minikube.sh        # Arranca el clúster, crea namespaces y configura /etc/hosts
│   ├── install-argocd.sh        # Instala ArgoCD via Helm y aplica el bootstrap App of Apps
│   ├── blue-green-switch.sh     # Conmutación Blue-Green con health checks y confirmación
│   └── backup-restore.sh        # Backup y restauración (Velero, PostgreSQL, Redis, ClickHouse)
│
├── terraform/
│   ├── main.tf                  # Bucket S3 + configuración (AWS real)
│   ├── iam.tf                   # IAM Role + IRSA para EKS (AWS real)
│   ├── variables.tf
│   ├── outputs.tf
│   └── localstack/              # Versión LocalStack para validación local
│       ├── main.tf
│       ├── iam.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── credentials-velero.example   # Plantilla de credenciales MinIO para Velero
├── Makefile                     # Automatización completa del despliegue
│
└── docs/
    ├── documentacion/           # Documentación técnica completa (ES + EN)
    └── propuesta_proyecto/      # Propuesta del proyecto
```

---

## Quick Start

### Requisitos

| Herramienta | Versión mínima | Propósito |
|---|---|---|
| Docker | cualquiera | Driver de Minikube |
| Minikube | v1.31 | Clúster Kubernetes local (requerido para K8s v1.28) |
| kubectl | v1.28 | CLI de Kubernetes |
| Helm | v3.8 | Gestión de charts (requerido para OCI y ArgoCD chart 7.7) |
| ArgoCD CLI | cualquiera | Gestión de aplicaciones ArgoCD |
| kubeseal | cualquiera | Cifrado de Sealed Secrets |
| velero CLI | cualquiera | Operaciones de backup |

> Los scripts `setup-minikube.sh` e `install-argocd.sh` verifican las versiones de Minikube y Helm automáticamente y fallan con un mensaje claro si no se cumplen.

---

### 1. Arrancar el clúster y configurar DNS

```bash
./scripts/setup-minikube.sh
```

El script es idempotente — si el clúster ya existe, lo omite. Al finalizar, configura automáticamente `/etc/hosts` con la IP del clúster para todos los dominios del proyecto.

---

### 2. Instalar Sealed Secrets

```bash
make sealed-secrets
```

Instala el controller de Sealed Secrets y aplica los secrets cifrados del repositorio.

> Los secrets de este repositorio están cifrados con la clave del clúster original. En un clúster nuevo hay que recrearlos. Ver [Adaptar el proyecto](#adaptar-el-proyecto-para-un-nuevo-entorno).

---

### 3. Instalar ArgoCD y hacer bootstrap

```bash
./scripts/install-argocd.sh
```

El script instala ArgoCD via Helm (`helm upgrade --install`), espera al secret del admin, aplica el AppProject y aplica el bootstrap Application (App of Apps). Al terminar imprime la URL de acceso y las credenciales iniciales.

ArgoCD sincronizará automáticamente todo lo que hay en `k8s/argocd/applications/` — la aplicación, observabilidad y backup.

```bash
# Verificar que las apps están sincronizando
kubectl get applications -n argocd -w
```

---

### 4. Instalar Velero

```bash
# Crear el archivo de credenciales de MinIO a partir de la plantilla
cp credentials-velero.example credentials-velero
# Editar credentials-velero con tus credenciales reales (no commitear este archivo)

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

### Acceso a los servicios

| Servicio | URL |
|---|---|
| Dashboard | http://openpanel.local |
| API | http://api.openpanel.local |
| ArgoCD | http://argocd.local |
| Grafana | http://grafana.local |
| Prometheus | http://prometheus.local |

```bash
# Abrir todas las UIs de una vez
make open
```

---

## Comandos de gestión del clúster

```bash
make status       # Estado general: cluster, namespaces, pods, apps ArgoCD
make stop         # Para Minikube sin eliminar el clúster
make restart      # Para y vuelve a arrancar Minikube
make dns          # Refresca /etc/hosts (útil si Minikube cambia de IP tras un restart)
make logs         # Logs en tiempo real de los pods de la API
make blue-green   # Ejecuta el switch Blue-Green de la API
make backup-run   # Crea un backup manual con Velero
make open         # Abre todas las UIs en el navegador
```

---

## Limpiar y arrancar desde cero

```bash
# Para y elimina el clúster + limpia /etc/hosts
make clean

# clean + elimina credentials-velero y repos de Helm
make clean-all
```

Para volver a desplegar después de limpiar:

```bash
make all GITHUB_USER=<usuario> GITHUB_TOKEN=<token>
```

---

## Pipeline CI/CD

El pipeline está dividido en tres workflows encadenados:

```
push / PR
    │
    ▼
ci-validate.yml          ← validación de manifiestos K8s, linting de Dockerfiles, escaneo de secrets
    │ (solo en master)
    ▼
ci-build-publish.yml     ← build de imágenes Docker, generación de SBOM, escaneo con Trivy
    │
    ▼
cd-update-tags.yml       ← actualiza image tags en Git, crea tag release/main-<sha>
    │
    ▼
ArgoCD detecta el commit y despliega automáticamente
```

- Las PRs solo ejecutan `ci-validate.yml` — nunca publican imágenes.
- `ci-validate.yml` ejecuta tres comprobaciones de infraestructura:
  - **kubeconform** — valida los manifiestos K8s (strict mode, schema K8s 1.28, verbose por recurso)
  - **kube-linter** — buenas prácticas de seguridad en los manifiestos (configurado en `.kube-linter.yaml`)
  - **hadolint** — linting de Dockerfiles (solo falla en errores, warnings de código upstream ignorados)
  - **Gitleaks** — detección de secrets accidentalmente commiteados
- El lint y tests de la aplicación están **desactivados intencionalmente** — este proyecto DevOps no es propietario del código fuente de OpenPanel. Ver comentario en `ci-validate.yml`.
- El SBOM (Software Bill of Materials) se genera en formato SPDX-JSON para cada imagen publicada.
- Trivy falla el pipeline si encuentra vulnerabilidades `CRITICAL` o `HIGH` con parche disponible.
- El CD hace `targetRevision` apuntar al tag `release/main-<sha>` — el despliegue es inmutable y reversible.

---

## Adaptar el Proyecto para un Nuevo Entorno

### 1. Usuario y repositorio de GitHub

```bash
# Sustituir el usuario en todo el directorio k8s/
find k8s/ -name "*.yaml" -exec sed -i \
  's/RubenLopSol/<TU_USUARIO_GITHUB>/g; s/rubenlopsol/<tu_usuario_minusculas>/g' {} +
```

Archivos afectados: ArgoCD Applications (repoURL), AppProject (sourceRepos) y Deployments (imagen GHCR).

También hay que crear la variable `REGISTRY_OWNER` en el repositorio de GitHub (el pipeline CI/CD la necesita para construir y publicar imágenes en GHCR):

```bash
gh variable set REGISTRY_OWNER \
  --repo <TU_USUARIO>/<REPO> \
  --body "<tu_usuario_en_minusculas>"
```

> `make setup-github` hace esto automáticamente al crear el repositorio.

---

### 2. Sealed Secrets — Recrear en el nuevo clúster

Los Sealed Secrets están cifrados con la clave del clúster original y no funcionan en otro clúster. Hay que recrearlos con `kubeseal` apuntando al nuevo clúster.

| Secret | Namespace | Claves requeridas |
|---|---|---|
| `postgres-credentials` | `openpanel` | `postgres-user`, `postgres-password` |
| `redis-credentials` | `openpanel` | `redis-password` |
| `clickhouse-credentials` | `openpanel` | `clickhouse-user`, `clickhouse-password` |
| `openpanel-secrets` | `openpanel` | `secret` (JWT secret) |
| `grafana-admin-credentials` | `observability` | `admin-user`, `admin-password` |

```bash
kubectl create secret generic postgres-credentials \
  --from-literal=postgres-user=postgres \
  --from-literal=postgres-password=TU_PASSWORD \
  --namespace openpanel \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --format yaml \
  > k8s/argocd/sealed-secrets/postgres-credentials.yaml
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

```ini
# credentials-velero  (no commitear)
[default]
aws_access_key_id=TU_MINIO_ACCESS_KEY
aws_secret_access_key=TU_MINIO_SECRET_KEY
```

---

### Checklist de adaptación

- [ ] Sustituir `RubenLopSol` / `rubenlopsol` por tu usuario de GitHub
- [ ] Recrear todos los Sealed Secrets con la clave de tu nuevo clúster
- [ ] Actualizar las URLs en `configmap.yaml` si usas un dominio diferente
- [ ] Crear el archivo `credentials-velero` con tus credenciales de MinIO
- [ ] Fork del repositorio y actualizar los `repoURL` de ArgoCD a tu fork

---

## Documentación

**Guía de testing local** (issues conocidos, verificación de conexiones, troubleshooting): [`local-testing.md`](local-testing.md)

La documentación técnica completa está en [`docs/documentacion/`](docs/documentacion/) en español e inglés:

| Documento | Contenido |
|---|---|
| [ARCHITECTURE.md](docs/documentacion/ARCHITECTURE.md) | Arquitectura del sistema, diagramas, namespaces |
| [SETUP.md](docs/documentacion/SETUP.md) | Instalación paso a paso del entorno completo |
| [GITOPS.md](docs/documentacion/GITOPS.md) | Flujo GitOps, ArgoCD, App of Apps, Kustomize |
| [CICD.md](docs/documentacion/CICD.md) | Pipeline CI/CD, jobs, SBOM, estrategia de tags |
| [BLUE-GREEN.md](docs/documentacion/BLUE-GREEN.md) | Estrategia Blue-Green para la API |
| [OBSERVABILITY.md](docs/documentacion/OBSERVABILITY.md) | Prometheus, AlertManager, Grafana, Loki, Tempo |
| [BACKUP-RECOVERY.md](docs/documentacion/BACKUP-RECOVERY.md) | Velero + MinIO, schedules, restauración |
| [SECURITY.md](docs/documentacion/SECURITY.md) | Sealed Secrets, Network Policies, RBAC |
| [OPERATIONS.md](docs/documentacion/OPERATIONS.md) | Comandos de operación del sistema |
| [RUNBOOK.md](docs/documentacion/RUNBOOK.md) | Procedimientos para despliegues e incidentes |
| [TERRAFORM.md](docs/documentacion/TERRAFORM.md) | Terraform para S3+IAM en AWS; validación local con LocalStack |
