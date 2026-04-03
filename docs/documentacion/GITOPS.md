# GitOps — Flujo de Despliegue con ArgoCD

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Principios GitOps

En este proyecto, Git actúa como la **única fuente de verdad** del estado del clúster. Esto significa:

- Toda la configuración de infraestructura y aplicación está versionada en Git
- Ningún cambio se aplica directamente al clúster sin pasar por Git
- ArgoCD monitoriza el repositorio y sincroniza el clúster automáticamente
- El estado deseado (Git) siempre converge hacia el estado real (clúster)

---

## Repositorio

```
https://github.com/RubenLopSol/proyecto-final-devops.git
Rama principal: master
```

> **Requisito:** El repositorio debe ser **público** para que ArgoCD pueda leer los manifiestos sin credenciales adicionales. Si el repositorio es privado, hay que registrar las credenciales en ArgoCD:
> ```bash
> kubectl create secret generic argocd-repo-creds \
>   -n argocd \
>   --from-literal=url=https://github.com/RubenLopSol \
>   --from-literal=username=RubenLopSol \
>   --from-literal=password=<GITHUB_PAT> \
>   --dry-run=client -o yaml | \
>   kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | \
>   kubectl apply -f -
> ```

### Estructura de manifiestos

```
k8s/
├── apps/                        ← Capa de aplicación (workloads)
│   ├── base/
│   │   └── openpanel/           ← Manifiestos base: API, Worker, DBs, Ingress
│   └── overlays/
│       ├── staging/             ← Minikube: 1 réplica, recursos reducidos
│       └── prod/                ← Producción: réplicas altas, TLS, PDB
└── infrastructure/              ← Capa de plataforma (cluster tooling)
    ├── base/
    │   ├── namespaces/          ← Definición de namespaces
    │   ├── observability/       ← Helm values base: Prometheus, Grafana, Loki, Tempo
    │   ├── backup/              ← MinIO + Velero daily schedule
    │   └── sealed-secrets/      ← Secrets cifrados con Sealed Secrets
    ├── overlays/
    │   ├── staging/             ← Minikube: PVC 5Gi, retención 3d
    │   └── prod/                ← Producción: PVC 50Gi, retención 30d, hourly backup
    └── argocd/
        ├── bootstrap-app.yaml   ← App of Apps raíz
        ├── applications/        ← ArgoCD Application CRDs
        └── projects/            ← ArgoCD Project CRD
```

---

## ArgoCD — Proyecto

El proyecto `openpanel` en ArgoCD agrupa las tres aplicaciones y define los permisos:

```yaml
# k8s/infrastructure/argocd/projects/openpanel-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: openpanel
  namespace: argocd
```

---

## App of Apps — Bootstrap

En lugar de aplicar manualmente `kubectl apply -f k8s/infrastructure/argocd/applications/` cada vez que se añade una aplicación, el proyecto usa el patrón **App of Apps**:

`k8s/infrastructure/argocd/bootstrap-app.yaml` es una ArgoCD Application que vigila el directorio `k8s/infrastructure/argocd/applications/` en la rama master. Cuando se añade o modifica cualquier Application en ese directorio, el bootstrap la detecta y la aplica automáticamente.

**Para arrancar todo el sistema:**

```bash
# Un solo comando tras instalar ArgoCD
kubectl apply -f k8s/infrastructure/argocd/bootstrap-app.yaml

# A partir de aquí ArgoCD gestiona todo lo demás automáticamente
```

**Ventajas:**
- Añadir una nueva aplicación = crear un YAML en `k8s/infrastructure/argocd/applications/` + push
- El CD pipeline puede actualizar el `targetRevision` de las Applications en Git — ArgoCD aplica el cambio sin intervención manual
- Auditable: cualquier cambio en las Applications queda en el historial de Git

---

![ArgoCD — Vista general de las 3 aplicaciones Synced + Healthy](../screenshots/argocd-apps-overview.png)

---

## ArgoCD — Aplicaciones

![ArgoCD — Recursos desplegados de la aplicación openpanel](../screenshots/argocd-openpanel-resources.png)

Se gestionan 7 aplicaciones ArgoCD:

| Aplicación | Fuente (path en Git) | Namespace destino | Sync | Wave |
|---|---|---|---|---|
| `bootstrap` | `k8s/infrastructure/argocd/applications/` | `argocd` | Automático | — |
| `namespaces` | `k8s/infrastructure/base/namespaces` | `argocd` | Automático | 0 |
| `sealed-secrets` | `k8s/infrastructure/overlays/staging/sealed-secrets` | `sealed-secrets` | Automático | 1 |
| `observability` | `k8s/infrastructure/overlays/staging/observability` | `observability` | Automático | 2 |
| `minio` | `k8s/infrastructure/overlays/staging/minio` | `backup` | Automático | 2 |
| `velero` | `k8s/infrastructure/overlays/staging/velero` | `velero` | Automático | 2 |
| `openpanel` | `k8s/apps/overlays/staging` | `openpanel` | Automático | 3 |

La app `observability` usa **kustomize + helmChartInflationGenerator** (`--enable-helm`): el overlay renderiza los cuatro charts (kube-prometheus-stack, loki, promtail, tempo) con los values del repositorio en una sola pasada de `kustomize build`. ArgoCD pasa `buildOptions: "--enable-helm"` al llamar a kustomize.

La app `sealed-secrets` también usa `--enable-helm` para renderizar el chart del controller, y además incluye el archivo `secrets.yaml` con los SealedSecrets cifrados.

### Orden de despliegue — Sync Waves

Las seis Application CRs llevan la anotación `argocd.argoproj.io/sync-wave`. ArgoCD no avanza a la siguiente wave hasta que todos los recursos de la wave anterior están en estado `Healthy`. Esto garantiza el orden plataforma-primero / aplicación-después:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"   # namespaces
    argocd.argoproj.io/sync-wave: "1"   # sealed-secrets
    argocd.argoproj.io/sync-wave: "2"   # observability, minio, velero
    argocd.argoproj.io/sync-wave: "3"   # openpanel
```

| Wave | Apps | Motivo |
|---|---|---|
| 0 | `namespaces` | Los namespaces deben existir antes de que cualquier app despliegue recursos en ellos |
| 1 | `sealed-secrets` | El controller debe estar en marcha y los Secrets descifrados antes de que los pods lean credenciales |
| 2 | `observability`, `minio`, `velero` | Capa de plataforma: Prometheus, Grafana, Loki, Tempo, MinIO y los CRDs de Velero listos |
| 3 | `openpanel` | La aplicación arranca con observabilidad completa, secrets y backup ya operativos |

Esto significa que los pods de OpenPanel inician con Prometheus ya haciendo scraping, Promtail ya recogiendo logs y Grafana ya disponible — no hay huecos en métricas ni en historial de logs desde el primer día.

### Configuración de sync automático

```yaml
syncPolicy:
  automated:
    prune: true        # Elimina recursos que ya no están en Git
    selfHeal: true     # Corrige desviaciones del estado deseado
    allowEmpty: false  # No permite borrar todos los recursos
  syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
```

**`selfHeal: true`** — Si alguien modifica un recurso directamente en el clúster (`kubectl edit`), ArgoCD lo revertirá en el siguiente ciclo de sync (cada ~3 minutos).

**`prune: true`** — Si se elimina un recurso del repositorio Git, ArgoCD lo eliminará también del clúster.

---

## Flujo de Despliegue GitOps

![Flujo de despliegue GitOps](../diagrams/img/flujo_despliegue_GitOps.png)
---

## Kustomize — Overlays (staging y prod)

El proyecto mantiene dos overlays siguiendo la convención estándar de Kustomize:

**`k8s/apps/overlays/staging`** — desplegado en Minikube por ArgoCD. Reduce réplicas y recursos para que el clúster local no se quede sin memoria:

```yaml
# k8s/apps/overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/namespaces
  - ../../base/openpanel

commonAnnotations:
  environment: staging
  managed-by: kustomize

patches:
  - path: patches/api-blue.yaml   # réplicas: 1, cpu: 100m, mem: 256Mi
  - path: patches/start.yaml      # cpu: 100m, mem: 128Mi
  - path: patches/worker.yaml     # cpu: 100m, mem: 256Mi
```

**`k8s/apps/overlays/prod`** — configuración para un clúster de producción real. Escala réplicas, añade TLS con cert-manager y un PodDisruptionBudget:

```yaml
# k8s/apps/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/namespaces
  - ../../base/openpanel
  - resources/pdb.yaml            # PodDisruptionBudget (solo en prod)

commonAnnotations:
  environment: prod
  managed-by: kustomize

patches:
  - path: patches/api-blue.yaml   # réplicas: 3
  - path: patches/worker.yaml     # réplicas: 2
  - path: patches/ingress.yaml    # TLS + dominios reales
  - path: patches/configmap.yaml  # URLs de producción
```

CI valida **ambos** overlays en cada PR — un patch roto en prod se detecta antes de llegar al clúster.

---

## Comandos ArgoCD Útiles

> **Prerequisito:** el CLI de ArgoCD requiere login previo contra el servidor. Ejecutar una vez por sesión:
> ```bash
> kubectl port-forward svc/argocd-server -n argocd 8080:80 &
> argocd login localhost:8080 --insecure \
>   --username admin \
>   --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
>     -o jsonpath="{.data.password}" | base64 -d)
> ```

```bash
# Ver estado de todas las apps
argocd app list

# Sincronizar manualmente una app
argocd app sync openpanel

# Ver el historial de despliegues
argocd app history openpanel

# Hacer rollback a una versión anterior
argocd app rollback openpanel <revision-id>

# Ver el historial de tags de release (despliegues)
git tag --list 'release/*' --sort=-version:refname | head -10

# Hacer rollback a un release tag anterior via GitOps:
# 1. Editar k8s/infrastructure/argocd/applications/openpanel-app.yaml
# 2. Cambiar targetRevision al tag deseado
# 3. git add + commit + push → ArgoCD aplica el cambio

# Ver diferencias entre Git y el clúster
argocd app diff openpanel

# Forzar sincronización (incluso sin cambios)
argocd app sync openpanel --force
```

---

## Gestión de Secrets con Sealed Secrets

Los secrets no pueden almacenarse en texto plano en Git. Se utiliza Sealed Secrets para cifrarlos con la clave pública RSA del clúster. Solo el controller del clúster puede descifrarlos.

### Cómo se generan

Todos los secrets del proyecto se gestionan en un único archivo por entorno:

```
k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
k8s/infrastructure/overlays/prod/sealed-secrets/secrets.yaml
```

Para regenerar el archivo (p.ej. tras recrear el clúster o rotar credenciales):

```bash
# Staging con valores por defecto del .secrets
make reseal-secrets ENV=staging

# Prod con credenciales fuertes
make reseal-secrets ENV=prod \
  POSTGRES_PASSWORD=xxx REDIS_PASSWORD=xxx CLICKHOUSE_PASSWORD=xxx \
  API_SECRET=$(openssl rand -hex 32) GRAFANA_PASSWORD=xxx MINIO_PASSWORD=xxx
```

`make reseal-secrets` obtiene el certificado del controller, crea cada Secret en memoria con `kubectl create --dry-run`, lo cifra con `kubeseal`, y los escribe todos en el archivo. Es seguro commitear el resultado — los valores son blobs RSA-cifrados.

### Secrets gestionados

| Secret | Namespace destino | Contenido |
|---|---|---|
| `postgres-credentials` | `openpanel` | usuario y contraseña de PostgreSQL |
| `redis-credentials` | `openpanel` | contraseña de Redis |
| `clickhouse-credentials` | `openpanel` | usuario y contraseña de ClickHouse |
| `openpanel-secrets` | `openpanel` | DATABASE_URL, CLICKHOUSE_URL, REDIS_URL, API_SECRET |
| `grafana-admin-credentials` | `observability` | usuario y contraseña de Grafana |
| `minio-credentials` | `backup` | MINIO_ROOT_USER, MINIO_ROOT_PASSWORD |

---

## Verificar Estado GitOps

```bash
# Estado de applications en ArgoCD
kubectl get applications -n argocd

# Ver eventos de sync
kubectl describe application openpanel -n argocd

# Verificar que ArgoCD está en sync
kubectl get application openpanel -n argocd \
  -o jsonpath='{.status.sync.status}'
# Debe devolver: Synced
```
