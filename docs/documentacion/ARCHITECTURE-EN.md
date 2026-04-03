# System Architecture — OpenPanel on Kubernetes

**Final Project — Master in DevOps & Cloud Computing**

**Student:** Rubén López Solé

**Specialization:** GitOps

**Date:** March 2026

---

## Overview

OpenPanel is a web analytics platform deployed on a local Kubernetes cluster (Minikube). The architecture clearly separates data ingestion, processing, and visualization, with a full observability stack and an automated GitOps workflow managed by ArgoCD.

![Application Architecture](../diagrams/img/architecture-1.png)

---

## Application Services

| Service | Image | Port | Description |
|---|---|---|---|
| **API** | `ghcr.io/rubenlopsol/openpanel-api` | 3000 | Receives events and responds to the Dashboard |
| **Dashboard (Start)** | `ghcr.io/rubenlopsol/openpanel-start` | 3000 | User web interface (Next.js) |
| **Worker** | `ghcr.io/rubenlopsol/openpanel-worker` | — | Background processing (BullMQ) |

### Databases

| Database | Technology | Port | Usage |
|---|---|---|---|
| **PostgreSQL** | StatefulSet | 5432 | Users, projects, configurations |
| **ClickHouse** | StatefulSet | 8123 / 9000 | Analytics events (high volume) |
| **Redis** | Deployment | 6379 | Job queues and cache |

---

## Data Flow


![Data Flow](../diagrams/img/Flujo_datos_app.png)

---

## Kubernetes Namespaces

| Namespace | Contents |
|---|---|
| `openpanel` | API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis |
| `observability` | Prometheus, Grafana, Loki, Promtail, Tempo, exporters |
| `argocd` | ArgoCD (GitOps controller) |
| `backup` | MinIO (object storage for backups) |
| `velero` | Velero (backup controller) |
| `ingress-nginx` | Ingress Controller |
| `sealed-secrets` | Sealed Secrets Controller |

![Cluster — All pods in Running state](../screenshots/cluster-all-pods-running.png)

![OpenPanel — Application running in the browser](../screenshots/openpanel-app-running.png)

---

## Repository Structure

```
proyecto_final/
├── .github/
│   └── workflows/
│       ├── ci-validate.yml        # CI-Lint-Test-Validate (quality gate)
│       ├── ci-build-publish.yml   # CI-Build-Publish (builds and publishes images)
│       └── cd-update-tags.yml     # CD-Update-GitOps-Manifests (updates tags)
├── .kube-linter.yaml              # Selective kube-linter checks (CI)
├── .hadolint.yaml                 # Ignored hadolint rules for upstream Dockerfiles (CI)
├── k8s/
│   ├── apps/                      # Application layer (workloads)
│   │   ├── base/
│   │   │   └── openpanel/         # Base manifests: API, Dashboard, Worker, DBs, Ingress
│   │   └── overlays/
│   │       ├── staging/           # Minikube: 1 replica, reduced resources
│   │       └── prod/              # Production: higher replicas, TLS, PDB
│   └── infrastructure/            # Platform layer (cluster tooling)
│       ├── base/
│       │   ├── namespaces/        # Namespace definitions (shared across environments)
│       │   ├── observability/     # Base Helm values: Prometheus, Grafana, Loki, Tempo
│       │   ├── backup/            # MinIO + Velero daily schedule (base)
│       │   └── sealed-secrets/    # Secrets encrypted with Sealed Secrets
│       ├── overlays/
│       │   ├── staging/           # Minikube: 5Gi PVC, 3d retention, reduced resources
│       │   └── prod/              # Production: 50Gi PVC, 30d retention, hourly backup
│       └── argocd/
│           ├── applications/      # ArgoCD Application manifests (App of Apps)
│           ├── projects/          # ArgoCD AppProject
│           └── bootstrap-app.yaml # Bootstrap — starts the entire stack
├── openpanel/                     # Application source code
└── docs/                          # Project documentation
```

---

## Kubernetes Infrastructure

![Kubernetes Infrastructure](../diagrams/img/Infra_kubernetes.png)

### Infrastructure Components

| Component | Version / Technology | Purpose |
|---|---|---|
| Minikube | v1.32+ | Local Kubernetes cluster |
| Kubernetes | v1.28 | Container orchestration |
| Ingress NGINX | helm chart | Service exposure |
| ArgoCD | v2.x (Helm chart) | GitOps controller |
| kube-prometheus-stack | Helm chart | Prometheus + Grafana + Node Exporter |
| Loki | Helm chart | Log aggregation |
| Promtail | Helm chart | Log collection (DaemonSet) |
| Tempo | Helm chart | Distributed tracing |
| Sealed Secrets | helm chart | Secure secrets management |
| Velero | v1.x | Backup and restore |
| MinIO | latest | Object storage for backups |

---

## Design Decisions

### Why Kustomize and not Helm?
Kustomize allows maintaining pure YAML manifests versioned in Git, without additional abstractions. Overlays allow customizing the local cluster without duplicating configuration.

The main advantage is being able to support multiple environments (local, staging, production) with the **minimum possible code**, only modifying what changes in each one:

```
k8s/
├── base/              → configuration common to all environments (written only once)
└── overlays/
    ├── dev/           → only what changes in Minikube (1 replica, reduced resources)
    └── prod/          → only what changes in production (3 replicas, TLS, PDB)
```

Each overlay only defines its differences relative to `base/`. No YAML is repeated. If something common to all environments needs to change, it is changed once in `base/` and all overlays inherit it automatically.

### Why ArgoCD for CD?
ArgoCD implements the pure GitOps model: the cluster state always converges toward what is in Git. It enables immediate rollbacks and full auditability of deployments.

### Why Blue-Green only for the API?
The API is the most critical component of the system (the entry point for all events). Blue-Green guarantees zero-downtime and rollback in seconds. The Dashboard and Worker have lower availability impact.

### Why Sealed Secrets?
In GitOps, everything must be in Git — including secrets. Sealed Secrets encrypts secrets with the cluster's public key, allowing them to be safely committed. Only the cluster controller can decrypt them.
