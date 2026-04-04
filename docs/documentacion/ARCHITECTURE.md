# Arquitectura del Sistema — OpenPanel en Kubernetes

**Proyecto Final — Master DevOps & Cloud Computing**

**Alumno:** Rubén López Solé 

**Especialidad:** GitOps

**Fecha:** Marzo 2026

---

## Visión General

OpenPanel es una plataforma de analítica web desplegada sobre un clúster local de Kubernetes (Minikube). La arquitectura separa claramente la ingesta de datos, el procesamiento y la visualización, con un stack de observabilidad completo y un flujo GitOps automatizado gestionado por ArgoCD.

![Arquitectura de la Aplicación](../diagrams/img/architecture-1.png)

---

## Servicios de la Aplicación

| Servicio | Imagen | Puerto | Descripción |
|---|---|---|---|
| **API** | `ghcr.io/rubenlopsol/openpanel-api` | 3000 | Recibe eventos y responde al Dashboard |
| **Dashboard (Start)** | `ghcr.io/rubenlopsol/openpanel-start` | 3000 | Interfaz web del usuario (Next.js) |
| **Worker** | `ghcr.io/rubenlopsol/openpanel-worker` | — | Procesamiento en segundo plano (BullMQ) |

### Bases de Datos

| Base de Datos | Tecnología | Puerto | Uso |
|---|---|---|---|
| **PostgreSQL** | StatefulSet | 5432 | Usuarios, proyectos, configuraciones |
| **ClickHouse** | StatefulSet | 8123 / 9000 | Eventos de analytics (volumen alto) |
| **Redis** | Deployment | 6379 | Colas de trabajo y caché |

---

## Flujo de Datos


![Flujo de Datos](../diagrams/img/Flujo_datos_app.png)

---

## Namespaces de Kubernetes

| Namespace | Contenido |
|---|---|
| `openpanel` | API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis |
| `observability` | Prometheus, Grafana, Loki, Promtail, Tempo, exporters |
| `argocd` | ArgoCD (GitOps controller) |
| `backup` | MinIO (object storage para backups) |
| `velero` | Velero (backup controller y CRDs: BackupStorageLocation, Schedule) |
| `ingress-nginx` | Ingress Controller |
| `sealed-secrets` | Sealed Secrets Controller |

![Cluster — Todos los pods en estado Running](../screenshots/cluster-all-pods-running.png)

![OpenPanel — Aplicación funcionando en el navegador](../screenshots/openpanel-app-running.png)

---

## Estructura del Repositorio

```
proyecto_final/
├── .github/
│   └── workflows/
│       ├── ci-validate.yml        # CI-Lint-Test-Validate (gate de calidad)
│       ├── ci-build-publish.yml   # CI-Build-Publish (construye y publica imágenes)
│       └── cd-update-tags.yml     # CD-Update-GitOps-Manifests (actualiza tags)
├── .kube-linter.yaml              # Checks selectivos de kube-linter (CI)
├── .hadolint.yaml                 # Reglas ignoradas de hadolint (CI)
├── .gitleaks.toml                 # Allowlist de falsos positivos de Gitleaks
├── k8s/
│   ├── apps/                      # Capa de aplicación (workloads)
│   │   ├── base/
│   │   │   └── openpanel/
│   │   │       ├── api-deployment-blue.yaml     # API activa (tráfico live)
│   │   │       ├── api-deployment-green.yaml    # API standby (rollback)
│   │   │       ├── api-service.yaml             # puertos http(:3333) y metrics(:3000)
│   │   │       ├── servicemonitors.yaml         # ServiceMonitor para api, postgres, redis, clickhouse
│   │   │       ├── network-policies.yaml        # default-deny + reglas explícitas (incluye scraping Prometheus)
│   │   │       ├── postgres-statefulset.yaml    # postgres + postgres-exporter sidecar
│   │   │       ├── postgres-service.yaml        # puertos postgres(:5432) y metrics(:9187)
│   │   │       ├── redis-deployment.yaml        # redis + redis-exporter sidecar
│   │   │       ├── redis-service.yaml           # puertos redis(:6379) y metrics(:9121)
│   │   │       ├── clickhouse-statefulset.yaml  # clickhouse con métricas nativas
│   │   │       ├── clickhouse-service.yaml      # puertos http, native y metrics(:9363)
│   │   │       └── ...                          # worker, start, ingress, configmap, migrate-job
│   │   └── overlays/
│   │       ├── staging/           # Minikube: réplicas 1, recursos reducidos
│   │       └── prod/              # Producción: réplicas altas, TLS, PDB
│   └── infrastructure/            # Capa de plataforma (cluster tooling)
│       ├── base/observability/
│       │   ├── kube-prometheus-stack/values.yaml  # Prometheus + Grafana + AlertManager + alertas + dashboards
│       │   ├── loki/values.yaml                   # SingleBinary, structuredConfig inmemory rings
│       │   ├── promtail/values.yaml
│       │   └── tempo/values.yaml
│       ├── overlays/
│       │   ├── staging/observability/
│       │   │   ├── kube-prometheus-stack/         # recursos reducidos, scrapers control-plane desactivados
│       │   │   ├── loki/                          # lokiCanary desactivado
│       │   │   ├── promtail/
│       │   │   └── tempo/
│       │   └── prod/
│       └── argocd/
│           ├── base/applications/                 # 12 ArgoCD Application CRs
│           ├── projects/                          # ArgoCD AppProject
│           └── overlays/staging/argocd/           # patches de path/targetRevision por entorno
├── openpanel/                     # Código fuente de la aplicación
└── docs/                          # Documentación del proyecto
```

---

## Infraestructura Kubernetes

![Infraestructura Kubernetes](../diagrams/img/Infra_kubernetes.png)

### Componentes de Infraestructura

| Componente | Versión / Tecnología | Propósito |
|---|---|---|
| Minikube | v1.32+ | Clúster local de Kubernetes |
| Kubernetes | v1.28 | Orquestación de contenedores |
| Ingress NGINX | helm chart | Exposición de servicios |
| ArgoCD | v2.x (Helm chart) | GitOps controller |
| kube-prometheus-stack | Helm chart | Prometheus + Grafana + Node Exporter |
| Loki | Helm chart | Agregación de logs |
| Promtail | Helm chart | Recolección de logs (DaemonSet) |
| Tempo | Helm chart | Distributed tracing |
| Sealed Secrets | helm chart | Gestión segura de secrets |
| Velero | v1.x | Backup y restauración |
| MinIO | latest | Object storage para backups |

---

## Decisiones de Diseño

### ¿Por qué Kustomize y no Helm?
Kustomize permite mantener manifiestos YAML puros versionados en Git, sin abstracciones adicionales. Los overlays permiten personalizar el clúster local sin duplicar configuración.

La principal ventaja es poder soportar múltiples entornos (local, staging, producción) con el **mínimo código posible**, modificando únicamente lo que cambia en cada uno:

```
k8s/
├── base/              → configuración común a todos los entornos (se escribe una sola vez)
└── overlays/
    ├── dev/           → solo lo que cambia en Minikube (réplicas 1, recursos reducidos)
    └── prod/          → solo lo que cambia en producción (réplicas 3, TLS, PDB)
```

Cada overlay únicamente define sus diferencias respecto a `base/`. No se repite ningún YAML. Si hay que cambiar algo común a todos los entornos, se cambia una sola vez en `base/` y todos los overlays lo heredan automáticamente.

### ¿Por qué ArgoCD para CD?
ArgoCD implementa el modelo GitOps puro: el estado del clúster siempre converge hacia lo que está en Git. Permite rollbacks inmediatos y auditabilidad completa de despliegues.

### ¿Por qué Blue-Green solo en la API?
La API es el componente más crítico del sistema (punto de entrada de todos los eventos). Blue-Green garantiza zero-downtime y rollback en segundos. Dashboard y Worker tienen menor impacto en disponibilidad.

### ¿Por qué Sealed Secrets?
En GitOps, todo debe estar en Git — incluyendo secrets. Sealed Secrets cifra los secretos con la clave pública del clúster, permitiendo commitearlos de forma segura. Solo el controlador del clúster puede descifrarlos.
