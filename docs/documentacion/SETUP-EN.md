# Setup — Environment Configuration

**Final Project — Master in DevOps & Cloud Computing**

---

## Prerequisites

### Required tools

| Tool | Minimum version | Installation |
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

## 1. Start the Minikube Cluster

```bash
./scripts/setup-minikube.sh
```

This script is the very first thing you run on a fresh machine. Its job is to turn an empty laptop into a structured Kubernetes cluster ready to receive the entire infrastructure stack.

The first thing it does is **check that you have the required tools** — `minikube`, `kubectl`, and `docker`. If anything is missing it stops immediately with a clear error, before touching anything. It also verifies that your Minikube version meets the minimum (v1.31), which is required to run Kubernetes v1.28.

It then **starts the cluster** under the `devops-cluster` profile. The name is not `openpanel` because this cluster is not exclusive to OpenPanel — it is a general-purpose DevOps cluster that can host multiple applications. It creates **3 nodes** instead of the usual single-node setup:

```
devops-cluster       →  node 1: control-plane   (Kubernetes system components)
devops-cluster-m02   →  node 2: app workloads   (OpenPanel API, Worker, databases)
devops-cluster-m03   →  node 3: observability   (Prometheus, Grafana, Loki, Tempo)
```

Each node gets 4 CPUs and 4Gi of RAM (12 CPUs and 12Gi in total). Three addons are enabled: `ingress` to reach services by hostname, `metrics-server` for Kubernetes resource metrics, and `storage-provisioner` for dynamic PVC provisioning.

**After the cluster starts**, the script waits explicitly until all 3 nodes are `Ready` before continuing. This prevents race conditions where the next step (`kubectl label`) runs before a node has finished joining the cluster.

**Node labelling** is where the topology becomes real. The two workers get a `workload` label:

```bash
devops-cluster-m02   workload=app
devops-cluster-m03   workload=observability
```

Every OpenPanel Deployment and StatefulSet carries `nodeSelector: workload: app`, and every observability Helm chart carries `nodeSelector: workload: observability`. Kubernetes enforces the separation — a Prometheus spike cannot evict application pods, and a runaway database cannot starve the monitoring stack.

### Why separate node groups?

In real production environments, teams separate workloads into dedicated node pools. The reasons are:

**Resource isolation.** If Prometheus decides to ingest a large dataset and consumes all available CPU, application pods are completely unaffected because they are on a different node. Without separation, one noisy component can degrade everything else.

**Predictability.** When you know which workload goes to which node, you can size each group independently. The observability node can have more memory, the app node more CPU — you don't have to over-provision a single node to satisfy everyone at once.

**Effective replicas.** A Deployment with `replicas: 2` only has real high availability if its pods land on different nodes. On a single node, both replicas share the same failure point. With separate nodes, a node failure does not take down the entire application.

**Mirrors real production.** On EKS, GKE, or AKS you always define separate node pools for applications, databases, and observability. Doing the same on Minikube means Kubernetes manifests work unchanged when moving to production — `nodeSelector: workload: app` behaves identically locally and in the cloud, as long as the node pool carries the same label.

**Promtail is the exception.** As a DaemonSet, Promtail must run on every node to collect logs from all pods. Adding a `nodeSelector` would cause it to miss logs from pods on the app node. That is why Promtail carries no node selector.

Finally, the script applies the **namespaces** (`openpanel`, `observability`, `argocd`, `backup`) and updates `/etc/hosts` with the Minikube IP so that all `.local` domains resolve without a local DNS server. It prints next steps when done.

---

## 2. Install the Sealed Secrets Controller and apply secrets

> **Must be installed BEFORE ArgoCD** so that secrets are available when pods start.

A single command installs the controller (via kustomize + helm), waits for it to be ready, and seals all secrets with the cluster key:

```bash
make sealed-secrets ENV=staging
```

What it does internally:
1. Renders the controller chart with `kustomize build --enable-helm` and applies it
2. Waits for the controller pod to be `Ready`
3. Runs `make reseal-secrets` — fetches the cluster certificate and encrypts all 6 credentials into `k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml`
4. Re-applies via kustomize so the controller decrypts and creates the Secrets in their namespaces

The 6 Secrets the controller creates in the cluster:

| Secret | Namespace | Contents |
|---|---|---|
| `postgres-credentials` | `openpanel` | PostgreSQL username and password |
| `redis-credentials` | `openpanel` | Redis password |
| `clickhouse-credentials` | `openpanel` | ClickHouse username and password |
| `openpanel-secrets` | `openpanel` | Application variables |
| `grafana-admin-credentials` | `observability` | Grafana admin username and password |
| `minio-credentials` | `backup` | MinIO credentials |

```bash
# Verify that the controller is Running
kubectl get pods -n sealed-secrets

# Verify that the secrets are decrypted correctly
kubectl get secrets -n openpanel
kubectl get secrets -n observability
kubectl get secrets -n backup
```

> **Note:** Sealed Secrets are encrypted with the cluster's unique RSA key. On a new cluster restore the key (`make restore-sealing-key`) or re-seal with `make reseal-secrets ENV=staging`.

---

## 3. Install ArgoCD

Use the script included in the repository:

```bash
./scripts/install-argocd.sh
```

The script installs or updates ArgoCD via **Helm** (`argo/argo-cd`), waits for the admin secret to be available, applies the AppProject and starts the App of Apps bootstrap. At the end it displays the initial admin password.

The `helm upgrade --install` command makes the script idempotent — it can be run multiple times without error.

---

## 5. Deploy with ArgoCD

The `install-argocd.sh` script already applies the project and bootstrap automatically. No additional `kubectl apply` is needed.

ArgoCD will automatically sync all applications defined in `k8s/infrastructure/argocd/applications/`:

**12 ArgoCD applications** are managed, organised into sync waves to guarantee deployment order:

| Application | What it deploys | Wave |
|---|---|---|
| `namespaces` | All cluster namespaces | 0 |
| `sealed-secrets` | Controller + encrypted SealedSecrets | 1 |
| `local-path-provisioner` | Local StorageClass | 1 |
| `prometheus` | Prometheus + Grafana + AlertManager + rules + dashboards | 2 |
| `minio` | MinIO Deployment + PVC | 2 |
| `velero-operator` | Velero Operator CRDs | 2 |
| `loki` | Loki (log aggregation) | 3 |
| `promtail` | Promtail DaemonSet (log collection) | 3 |
| `tempo` | Tempo (distributed tracing) | 3 |
| `velero` | BackupStorageLocation + daily Schedule | 3 |
| `openpanel` | API, Dashboard, Worker, PostgreSQL, ClickHouse, Redis | 4 |

```bash
# Wait for ArgoCD to sync (may take 3-5 minutes for all waves)
kubectl get applications -n argocd -w
```

To manually sync a specific application:

```bash
argocd app sync openpanel
argocd app sync prometheus
argocd app sync loki
```

---

## 5. Deploy Backup (MinIO + Velero schedules)

MinIO and Velero schedules are deployed automatically by the `minio` and `velero` ArgoCD apps. To apply manually:

```bash
make backup ENV=staging
```

This applies the `minio` overlay in the `backup` namespace and the `velero` overlay in the `velero` namespace.

> **Note:** The Velero server must be installed separately (`velero install --namespace velero ...`). The schedules and BackupStorageLocation managed by kustomize are in the `velero` namespace.

---

## 6. Configure Local DNS

```bash
# Get the Minikube cluster IP
minikube ip -p devops-cluster

# Add to /etc/hosts (replace with the obtained IP)
echo "$(minikube ip -p devops-cluster) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local alertmanager.local" \
  | sudo tee -a /etc/hosts
```

> The `setup-minikube.sh` script already does this automatically when it finishes.

### Access URLs

| Service | URL | Credentials |
|---|---|---|
| Dashboard | http://openpanel.local | — |
| API | http://api.openpanel.local | — |
| ArgoCD | http://argocd.local | admin / see secret `argocd-initial-admin-secret` |
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | — |
| AlertManager | http://alertmanager.local | — |

---

## 8. Final Verification

```bash
# Status of all pods
kubectl get pods -A

# Status of ArgoCD applications (all should be Synced + Healthy)
kubectl get applications -n argocd

# Configured backup schedules
velero schedule get --namespace velero

# Verify that Prometheus scrapes the targets
kubectl port-forward svc/prometheus -n observability 9090:9090
# http://localhost:9090/targets — all should be in UP state
```

---

## Common Problem Resolution

| Problem | Cause | Solution |
|---|---|---|
| Pod in `CrashLoopBackOff` | Secret not found | `make sealed-secrets ENV=staging` or `argocd app sync sealed-secrets` |
| Ingress not responding | Incorrect Minikube IP | Re-run `minikube ip -p devops-cluster` and update `/etc/hosts` |
| Prometheus `lock DB` | TSDB lock not released | `kubectl delete pod -n observability -l app=prometheus` |
| ArgoCD `OutOfSync` | Manifests modified locally | `argocd app sync openpanel` |
| ArgoCD UI not loading | Incorrect port-forward | Use `http://argocd.local` directly (without port-forward) |
