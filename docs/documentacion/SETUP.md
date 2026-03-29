# Setup — Configuración del Entorno

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Requisitos Previos

### Herramientas necesarias

| Herramienta | Versión mínima | Instalación |
|---|---|---|
| `minikube` | v1.32+ | https://minikube.sigs.k8s.io |
| `kubectl` | v1.28+ | https://kubernetes.io/docs/tasks/tools |
| `helm` | v3.x | https://helm.sh/docs/intro/install |
| `kustomize` | v5.x | `brew install kustomize` |
| `kubeseal` | v0.24+ | https://github.com/bitnami-labs/sealed-secrets/releases |
| `velero` CLI | v1.x | https://velero.io/docs |
| `argocd` CLI | v2.x | https://argo-cd.readthedocs.io |
| `docker` | v24+ | https://docs.docker.com/engine/install |

---

## 1. Arrancar el Clúster Minikube

Usar el script incluido en el repositorio:

```bash
./scripts/setup-minikube.sh
```

El script crea el clúster con el perfil `openpanel`, habilita los addons `ingress` y `metrics-server`, aplica los namespaces base y muestra los pasos siguientes.

Si se prefiere lanzarlo manualmente:

```bash
minikube start \
  --profile=openpanel \
  --kubernetes-version=v1.28.0 \
  --driver=docker \
  --cpus=6 \
  --memory=8192 \
  --disk-size=60g \
  --addons=ingress,metrics-server,storage-provisioner

kubectl apply -f k8s/base/namespaces/namespaces.yaml
```

---

## 2. Instalar Sealed Secrets Controller

> **Debe instalarse ANTES que ArgoCD** para que los secrets estén disponibles cuando los pods arranquen.

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets \
  --create-namespace

# Verificar que el controller está Running
kubectl get pods -n sealed-secrets
```

---

## 3. Aplicar los Sealed Secrets

Todos los secrets necesarios están cifrados en el repositorio. Un solo comando los despliega todos:

```bash
kubectl apply -f k8s/argocd/sealed-secrets/
```

Esto crea automáticamente los siguientes secrets:

| Secret | Namespace | Contenido |
|---|---|---|
| `postgres-credentials` | `openpanel` | Usuario y contraseña de PostgreSQL |
| `redis-credentials` | `openpanel` | Contraseña de Redis |
| `clickhouse-credentials` | `openpanel` | Usuario y contraseña de ClickHouse |
| `openpanel-secrets` | `openpanel` | Variables de la aplicación |
| `grafana-admin-credentials` | `observability` | Usuario y contraseña de Grafana |
| `minio-credentials` | `backup` | Credenciales de MinIO |

```bash
# Verificar que se descifran correctamente
kubectl get secrets -n openpanel
kubectl get secrets -n observability
kubectl get secrets -n backup
```

> **Nota:** Los Sealed Secrets están cifrados con la clave del clúster original. En un clúster nuevo hay que recrearlos — ver [Adaptar el proyecto](../../README.md#adaptar-el-proyecto-para-un-nuevo-entorno).

---

## 4. Instalar ArgoCD

Usar el script incluido en el repositorio:

```bash
./scripts/install-argocd.sh
```

El script instala o actualiza ArgoCD via **Helm** (`argo/argo-cd`) usando el values file `k8s/helm/values/argocd.yaml`, espera a que el secret de admin esté disponible, aplica el AppProject y arranca el bootstrap de App of Apps. Al finalizar muestra la contraseña inicial del admin.

El comando `helm upgrade --install` hace el script idempotente — se puede ejecutar varias veces sin error.

---

## 5. Desplegar con ArgoCD

El script `install-argocd.sh` ya aplica el proyecto y el bootstrap automáticamente. No se necesita ningún `kubectl apply` adicional.

ArgoCD sincronizará automáticamente todas las aplicaciones definidas en `k8s/argocd/applications/`:

| Aplicación | Qué despliega |
|---|---|
| `openpanel` | API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis |
| `observability-prometheus` | Prometheus + Grafana + AlertManager + Node Exporter |
| `observability-loki` | Loki |
| `observability-promtail` | Promtail |
| `observability-tempo` | Tempo |
| `backup` | MinIO |

```bash
# Esperar a que ArgoCD sincronice (puede tardar 1-2 minutos)
kubectl get applications -n argocd -w
```

Para sincronizar manualmente una aplicación específica:

```bash
argocd app sync openpanel
```

---

## 6. Instalar Velero

```bash
# Crear el archivo de credenciales de MinIO (no commitear)
cat > velero-credentials <<EOF
[default]
aws_access_key_id=minioadmin
aws_secret_access_key=minio-secret-2024
EOF

# Instalar Velero apuntando a MinIO
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000

# Verificar instalación
kubectl get pods -n velero

# Aplicar los schedules de backup automático
kubectl apply -f k8s/base/backup/velero/schedule.yaml
```

---

## 7. Configurar DNS Local

```bash
# Obtener la IP del clúster Minikube
minikube ip -p openpanel

# Añadir al /etc/hosts (sustituir con la IP obtenida)
echo "$(minikube ip -p openpanel) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
  | sudo tee -a /etc/hosts
```

### URLs de acceso

| Servicio | URL | Credenciales |
|---|---|---|
| Dashboard | http://openpanel.local | — |
| API | http://api.openpanel.local | — |
| ArgoCD | http://argocd.local | admin / (ver paso 4) |
| Grafana | http://grafana.local | admin / admin123 |
| Prometheus | http://prometheus.local | — |

---

## 8. Verificación Final

```bash
# Estado de todos los pods
kubectl get pods -A

# Estado de ArgoCD applications (todos deben ser Synced + Healthy)
kubectl get applications -n argocd

# Schedules de backup configurados
velero schedule get --namespace velero

# Verificar que Prometheus scrape los targets
kubectl port-forward svc/prometheus -n observability 9090:9090
# http://localhost:9090/targets — todos deben estar en estado UP
```

---

## Resolución de Problemas Comunes

| Problema | Causa | Solución |
|---|---|---|
| Pod en `CrashLoopBackOff` | Secret no encontrado | `kubectl apply -f k8s/argocd/sealed-secrets/` |
| Ingress no responde | IP de Minikube incorrecta | Re-ejecutar `minikube ip -p openpanel` y actualizar `/etc/hosts` |
| Prometheus `lock DB` | TSDB lock no liberado | `kubectl delete pod -n observability -l app=prometheus` |
| ArgoCD `OutOfSync` | Manifiestos modificados localmente | `argocd app sync openpanel` |
| ArgoCD UI no carga | Port-forward incorrecto | Usar `http://argocd.local` directamente (sin port-forward) |
