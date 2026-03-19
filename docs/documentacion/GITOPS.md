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
https://github.com/RubenLopSol/proyecto_final.git
Rama principal: master / main
```

### Estructura de manifiestos

```
k8s/
├── base/                        ← Configuración base reutilizable
│   ├── namespaces/
│   ├── openpanel/               ← App: API, Dashboard, Worker, DBs
│   ├── observability/           ← Prometheus, Grafana, Loki, Tempo
│   └── backup/                  ← MinIO, Velero schedules
├── overlays/
│   └── local/                   ← Personalización para Minikube
│       ├── kustomization.yaml
│       └── patches/
│           └── resource-limits.yaml
└── argocd/
    ├── applications/            ← ArgoCD Application CRDs
    ├── projects/                ← ArgoCD Project CRD
    └── sealed-secrets/          ← Secrets cifrados
```

---

## ArgoCD — Proyecto

El proyecto `openpanel` en ArgoCD agrupa las tres aplicaciones y define los permisos:

```yaml
# k8s/argocd/projects/openpanel-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: openpanel
  namespace: argocd
```

---

## ArgoCD — Aplicaciones

Se gestionan 3 aplicaciones ArgoCD:

| Aplicación | Path en Git | Namespace destino | Sync |
|---|---|---|---|
| `openpanel` | `k8s/overlays/local` | `openpanel` | Automático |
| `observability` | `k8s/base/observability` | `observability` | Automático |
| `backup` | `k8s/base/backup` | `backup` | Automático |

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

```
┌─────────────────────────────────────────────────────────────┐
│                        GitHub                               │
│                                                             │
│  Developer ──push──► main branch                           │
│                           │                                 │
│                    GitHub Actions CI                        │
│                           │                                 │
│              ┌────────────┴────────────┐                    │
│              │                         │                    │
│         CI exitoso                  CI falla               │
│              │                         │                    │
│      CD pipeline actualiza          PR bloqueado            │
│      image tags en k8s/             (no merge)             │
│              │                                              │
└──────────────┼──────────────────────────────────────────────┘
               │
               ▼
        ArgoCD detecta cambio en Git
               │
               ▼
        ArgoCD sincroniza el clúster
               │
               ▼
        Nueva versión desplegada en Kubernetes
```

---

## Kustomize — Overlay Local

El overlay `k8s/overlays/local` referencia la base e incluye un patch para ajustar los límites de recursos al entorno Minikube:

```yaml
# k8s/overlays/local/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/namespaces
  - ../../base/openpanel

patches:
  - path: patches/resource-limits.yaml
```

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

# Ver diferencias entre Git y el clúster
argocd app diff openpanel

# Forzar sincronización (incluso sin cambios)
argocd app sync openpanel --force
```

---

## Gestión de Secrets con Sealed Secrets

Los secrets no pueden almacenarse en texto plano en Git. Se utiliza Sealed Secrets para cifrarlos.

### Crear un nuevo Sealed Secret

```bash
# Crear un secret temporal (sin aplicarlo al clúster)
kubectl create secret generic mi-secret \
  --from-literal=password=miPassword123 \
  --namespace openpanel \
  --dry-run=client \
  -o yaml | kubeseal \
  --controller-namespace sealed-secrets \
  --format yaml > k8s/argocd/sealed-secrets/mi-secret.yaml

# Commitear el SealedSecret al repositorio
git add k8s/argocd/sealed-secrets/mi-secret.yaml
git commit -m "feat: add sealed secret for mi-secret"
git push
```

### Estructura de secrets gestionados

| Secret | Namespace | Contenido |
|---|---|---|
| `postgres-credentials` | openpanel | usuario y contraseña de PostgreSQL |
| `redis-credentials` | openpanel | contraseña de Redis |
| `clickhouse-credentials` | openpanel | usuario y contraseña de ClickHouse |
| `openpanel-secrets` | openpanel | tokens y variables de la aplicación |

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
