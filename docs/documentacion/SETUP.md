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

```bash
./scripts/setup-minikube.sh
```

Este script es lo primero que ejecutas en una máquina desde cero. Su misión es convertir un portátil vacío en un clúster Kubernetes estructurado y listo para recibir toda la infraestructura.

Lo primero que hace es **verificar que tienes las herramientas necesarias** — `minikube`, `kubectl` y `docker`. Si falta alguna, el script se detiene con un error claro antes de tocar nada. También comprueba que la versión de Minikube es la mínima requerida (v1.31), necesaria para correr Kubernetes v1.28.

A continuación **arranca el clúster** con el perfil `devops-cluster`. El nombre no es `openpanel` porque este clúster no es exclusivo de OpenPanel — es un clúster de propósito general que puede alojar múltiples aplicaciones. Se crean **3 nodos** en lugar del nodo único habitual:

```
devops-cluster       →  nodo 1: control-plane   (componentes del sistema Kubernetes)
devops-cluster-m02   →  nodo 2: cargas de app   (OpenPanel API, Worker, bases de datos)
devops-cluster-m03   →  nodo 3: observabilidad  (Prometheus, Grafana, Loki, Tempo)
```

Cada nodo recibe 4 CPUs y 4Gi de RAM (12 CPUs y 12Gi en total). Se habilitan tres addons: `ingress` para acceder a los servicios por nombre de host, `metrics-server` para métricas de recursos de Kubernetes, y `storage-provisioner` para el aprovisionamiento dinámico de PVCs.

**Después de arrancar**, el script espera explícitamente a que los 3 nodos estén en estado `Ready` antes de continuar. Esto evita condiciones de carrera en las que el siguiente paso (`kubectl label`) se ejecuta antes de que un nodo haya terminado de unirse al clúster.

**El etiquetado de nodos** es donde la topología se hace efectiva. Los dos workers reciben la etiqueta `workload`:

```bash
devops-cluster-m02   workload=app
devops-cluster-m03   workload=observability
```

Todos los Deployments y StatefulSets de OpenPanel tienen `nodeSelector: workload: app`, y todos los charts de observabilidad tienen `nodeSelector: workload: observability`. Kubernetes hace cumplir el aislamiento: un pico de Prometheus no puede desalojar pods de la aplicación, y una base de datos desbocada no puede agotar los recursos del stack de monitorización.

### ¿Por qué separar los nodos por grupo de trabajo?

En producción real, los equipos separan las cargas de trabajo en grupos de nodos dedicados (node pools). Las razones son:

**Aislamiento de recursos.** Si Prometheus decide hacer una ingesta masiva y consume toda la CPU disponible, los pods de la aplicación no se ven afectados porque están en un nodo diferente. Sin separación, un componente ruidoso puede degradar a todos los demás.

**Predecibilidad.** Cuando sabes qué workload va a cada nodo, puedes dimensionar cada grupo de forma independiente. El nodo de observabilidad puede tener más memoria, el nodo de aplicación más CPU — no tienes que sobre-aprovisionar un nodo único para satisfacer a todos a la vez.

**Réplicas efectivas.** Un Deployment con `replicas: 2` solo tiene alta disponibilidad real si sus pods acaban en nodos distintos. Con un único nodo, las dos réplicas comparten el mismo punto de fallo. Con nodos separados, un fallo de nodo no tumba toda la aplicación.

**Refleja el mundo real.** En EKS, GKE o AKS siempre se definen node pools distintos para aplicaciones, bases de datos y observabilidad. Hacer lo mismo en Minikube significa que los manifiestos de Kubernetes funcionan sin cambios al pasar a producción — el `nodeSelector: workload: app` funciona igual en local que en la nube, siempre que el node pool tenga la misma etiqueta.

**Promtail es la excepción.** Como DaemonSet, Promtail debe correr en todos los nodos para recoger los logs de todos los pods. Añadirle un `nodeSelector` haría que perdiera los logs de los pods del nodo de aplicación. Por eso Promtail no lleva selector de nodo.

Por último, el script aplica los **namespaces** (`openpanel`, `observability`, `argocd`, `backup`) y actualiza `/etc/hosts` con la IP de Minikube para que todos los dominios `.local` resuelvan sin necesidad de un servidor DNS local. Al terminar imprime los siguientes pasos.

---

## 2. Instalar Sealed Secrets Controller y aplicar secrets

> **Debe instalarse ANTES que ArgoCD** para que los secrets estén disponibles cuando los pods arranquen.

Un solo comando instala el controller (via kustomize + helm), espera a que esté listo, y cifra todos los secrets con la clave del clúster:

```bash
make sealed-secrets ENV=staging
```

Lo que hace internamente:
1. Renderiza el chart del controller con `kustomize build --enable-helm` y lo aplica
2. Espera a que el pod del controller esté `Ready`
3. Ejecuta `make reseal-secrets` — obtiene el certificado del clúster y cifra las 6 credenciales en `k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml`
4. Re-aplica vía kustomize para que el controller descifre y cree los Secrets en sus namespaces

Los 6 Secrets que crea el controller en el clúster:

| Secret | Namespace | Contenido |
|---|---|---|
| `postgres-credentials` | `openpanel` | Usuario y contraseña de PostgreSQL |
| `redis-credentials` | `openpanel` | Contraseña de Redis |
| `clickhouse-credentials` | `openpanel` | Usuario y contraseña de ClickHouse |
| `openpanel-secrets` | `openpanel` | Variables de la aplicación |
| `grafana-admin-credentials` | `observability` | Usuario y contraseña de Grafana |
| `minio-credentials` | `backup` | Credenciales de MinIO |

```bash
# Verificar que el controller está Running
kubectl get pods -n sealed-secrets

# Verificar que los secrets se descifran correctamente
kubectl get secrets -n openpanel
kubectl get secrets -n observability
kubectl get secrets -n backup
```

> **Nota:** Los Sealed Secrets se cifran con la clave RSA única del clúster. En un clúster nuevo hay que restaurar la clave (ver `make restore-sealing-key`) o volver a sellar con `make reseal-secrets ENV=staging`.

---

## 3. Instalar ArgoCD

Usar el script incluido en el repositorio:

```bash
./scripts/install-argocd.sh
```

El script instala o actualiza ArgoCD via **Helm** (`argo/argo-cd`), espera a que el secret de admin esté disponible, aplica el AppProject y arranca el bootstrap de App of Apps. Al finalizar muestra la contraseña inicial del admin.

El comando `helm upgrade --install` hace el script idempotente — se puede ejecutar varias veces sin error.

---

## 4. Desplegar con ArgoCD

El script `install-argocd.sh` ya aplica el proyecto y el bootstrap automáticamente. No se necesita ningún `kubectl apply` adicional.

ArgoCD sincronizará automáticamente todas las aplicaciones definidas en `k8s/infrastructure/argocd/applications/`:

Se gestionan **12 aplicaciones ArgoCD** organizadas en sync waves para garantizar el orden de despliegue:

| Aplicación | Qué despliega | Wave |
|---|---|---|
| `namespaces` | Todos los namespaces del clúster | 0 |
| `sealed-secrets` | Controller + SealedSecrets cifrados | 1 |
| `local-path-provisioner` | StorageClass local | 1 |
| `prometheus` | Prometheus + Grafana + AlertManager + reglas + dashboards | 2 |
| `minio` | MinIO Deployment + PVC | 2 |
| `velero-operator` | Velero Operator CRDs | 2 |
| `loki` | Loki (log aggregation) | 3 |
| `promtail` | Promtail DaemonSet (log collection) | 3 |
| `tempo` | Tempo (distributed tracing) | 3 |
| `velero` | BackupStorageLocation + Schedule diario | 3 |
| `openpanel` | API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis | 4 |

```bash
# Esperar a que ArgoCD sincronice (puede tardar 3-5 minutos para todas las waves)
kubectl get applications -n argocd -w
```

Para sincronizar manualmente una aplicación específica:

```bash
argocd app sync openpanel
argocd app sync prometheus
argocd app sync loki
```

---

## 5. Desplegar Backup (MinIO + Velero schedules)

MinIO y los schedules de Velero se despliegan automáticamente por las apps ArgoCD `minio` y `velero`. Para aplicarlos manualmente:

```bash
make backup ENV=staging
```

Esto aplica el overlay de `minio` en el namespace `backup` y el overlay de `velero` en el namespace `velero`.

> **Nota:** El servidor de Velero debe instalarse de forma separada (`velero install --namespace velero ...`). Los schedules y la BackupStorageLocation que gestiona kustomize están en el namespace `velero`.

---

## 6. Configurar DNS Local

```bash
# Obtener la IP del clúster Minikube
minikube ip -p devops-cluster

# Añadir al /etc/hosts (sustituir con la IP obtenida)
echo "$(minikube ip -p devops-cluster) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local alertmanager.local" \
  | sudo tee -a /etc/hosts
```

> El script `setup-minikube.sh` ya hace esto automáticamente al finalizar.

### URLs de acceso

| Servicio | URL | Credenciales |
|---|---|---|
| Dashboard | http://openpanel.local | — |
| API | http://api.openpanel.local | — |
| ArgoCD | http://argocd.local | admin / ver secret `argocd-initial-admin-secret` |
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | — |
| AlertManager | http://alertmanager.local | — |

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
| Pod en `CrashLoopBackOff` | Secret no encontrado | `make sealed-secrets ENV=staging` o `argocd app sync sealed-secrets` |
| Ingress no responde | IP de Minikube incorrecta | Re-ejecutar `minikube ip -p devops-cluster` y actualizar `/etc/hosts` |
| Prometheus `lock DB` | TSDB lock no liberado | `kubectl delete pod -n observability -l app=prometheus` |
| ArgoCD `OutOfSync` | Manifiestos modificados localmente | `argocd app sync openpanel` |
| ArgoCD UI no carga | Port-forward incorrecto | Usar `http://argocd.local` directamente (sin port-forward) |
