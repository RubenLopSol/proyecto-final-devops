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
| `velero` | Velero (backup controller) |
| `ingress-nginx` | Ingress Controller |
| `sealed-secrets` | Sealed Secrets Controller |

---

## Estructura del Repositorio

```
proyecto_final/
├── .github/
│   └── workflows/
│       ├── ci.yml          # Pipeline CI (lint, build, scan)
│       └── cd.yml          # Pipeline CD (actualiza tags en manifiestos)
├── k8s/
│   ├── base/
│   │   ├── namespaces/     # Definición de namespaces
│   │   ├── openpanel/      # Manifiestos de la aplicación
│   │   ├── observability/  # Prometheus, Grafana, Loki, Tempo
│   │   └── backup/         # MinIO, Velero schedules
│   ├── overlays/
│   │   └── local/          # Overlay Minikube (resource limits patch)
│   └── argocd/
│       ├── applications/   # ArgoCD Application manifests
│       ├── projects/       # ArgoCD Project
│       └── sealed-secrets/ # Secrets cifrados
├── openpanel/              # Código fuente de la aplicación
└── docs/                   # Documentación del proyecto
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
| ArgoCD | v2.x | GitOps controller |
| Sealed Secrets | helm chart | Gestión segura de secrets |
| Velero | v1.x | Backup y restauración |
| MinIO | latest | Object storage para backups |

---

## Decisiones de Diseño

### ¿Por qué Kustomize y no Helm?
Kustomize permite mantener manifiestos YAML puros versionados en Git, sin abstracciones adicionales. Los overlays permiten personalizar el clúster local sin duplicar configuración.

### ¿Por qué ArgoCD para CD?
ArgoCD implementa el modelo GitOps puro: el estado del clúster siempre converge hacia lo que está en Git. Permite rollbacks inmediatos y auditabilidad completa de despliegues.

### ¿Por qué Blue-Green solo en la API?
La API es el componente más crítico del sistema (punto de entrada de todos los eventos). Blue-Green garantiza zero-downtime y rollback en segundos. Dashboard y Worker tienen menor impacto en disponibilidad.

### ¿Por qué Sealed Secrets?
En GitOps, todo debe estar en Git — incluyendo secrets. Sealed Secrets cifra los secretos con la clave pública del clúster, permitiendo commitearlos de forma segura. Solo el controlador del clúster puede descifrarlos.
