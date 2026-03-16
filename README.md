# OpenPanel DevOps Project

Pipeline DevOps completo para [OpenPanel](https://github.com/Openpanel-dev/openpanel) con GitOps (ArgoCD), observabilidad (Prometheus + Grafana + Loki + Tempo), Blue-Green deployment y backup automatizado.

**Especialidad:** GitOps con ArgoCD
**Autor:** Ruben Lopez Sole

## Estructura del proyecto

```
proyecto_final/
├── openpanel/              # Aplicacion OpenPanel (fork)
├── k8s/                    # Manifiestos Kubernetes
│   ├── base/               #   Recursos base
│   │   ├── namespaces/     #     Definicion de namespaces
│   │   ├── openpanel/      #     API, Start, Worker, DBs
│   │   ├── observability/  #     Prometheus, Grafana, Loki, Tempo
│   │   └── backup/         #     Velero, MinIO
│   ├── overlays/           #   Kustomize por ambiente
│   │   └── local/          #     Configuracion para Minikube
│   └── argocd/             #   ArgoCD Applications y Projects
├── .github/workflows/      # CI/CD con GitHub Actions
├── scripts/                # Scripts de automatizacion
└── docs/                   # Documentacion del proyecto
```

## Quick Start

### Requisitos

- Docker
- Minikube
- kubectl
- ArgoCD CLI
- kubeseal (Sealed Secrets)

### Setup

```bash
# 1. Levantar el cluster
./scripts/setup-minikube.sh

# 2. Instalar ArgoCD
./scripts/install-argocd.sh

# 3. Aplicar ArgoCD Applications
kubectl apply -f k8s/argocd/projects/
kubectl apply -f k8s/argocd/applications/

# 4. Configurar DNS local
echo "$(minikube ip -p openpanel) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" | sudo tee -a /etc/hosts
```

### Acceso

| Servicio | URL |
|---|---|
| Dashboard | http://openpanel.local |
| API | http://api.openpanel.local |
| ArgoCD | https://argocd.local |
| Grafana | http://grafana.local |
| Prometheus | http://prometheus.local |

## Stack

| Componente | Herramienta |
|---|---|
| Orquestacion | Kubernetes (Minikube) |
| GitOps / CD | ArgoCD |
| CI | GitHub Actions |
| Registry | GitHub Container Registry |
| Metricas | Prometheus |
| Logs | Loki + Promtail |
| Traces | Tempo |
| Dashboards | Grafana |
| Secrets | Sealed Secrets (Bitnami) |
| Backup | Velero + MinIO |
| Deployment | Blue-Green |
