# Observability — Metrics, Logs and Traces

**Final Project — Master in DevOps & Cloud Computing**

---

## Observability Stack

The system implements the three pillars of observability:

| Pillar | Tool | Port | Description |
|---|---|---|---|
| **Metrics** | Prometheus | 9090 | Collects time-series metrics via ServiceMonitors |
| **Logs** | Loki + Promtail | 3100 | Aggregates logs from all cluster pods |
| **Traces** | Tempo | 3200 / 4317 | Distributed tracing (OTLP) |
| **Dashboards** | Grafana | 3000 | Unified visualisation with correlated datasources |
| **Alerts** | AlertManager | 9093 | Alert routing and suppression |

All components are deployed to the `observability` namespace via **official Helm charts** managed by **4 independent ArgoCD applications**.

### Access URLs (staging / Minikube)

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | — |
| AlertManager | http://alertmanager.local | — |

> Grafana credentials come from the `grafana-admin-credentials` secret in the `observability` namespace.
> Retrieve with: `kubectl get secret grafana-admin-credentials -n observability -o jsonpath='{.data.admin-password}' | base64 -d`

---

## Deployment — 4 Independent ArgoCD Applications

The observability stack is split into **4 independent ArgoCD Applications**, each managing a single Helm chart. This allows syncing or debugging one component without affecting the others.

| ArgoCD App | Chart | Version | Sync Wave | Path |
|---|---|---|---|---|
| `prometheus` | `kube-prometheus-stack` | 65.1.1 | 2 | `overlays/staging/observability/kube-prometheus-stack` |
| `loki` | `grafana/loki` | 6.6.2 | 3 | `overlays/staging/observability/loki` |
| `promtail` | `grafana/promtail` | 6.16.4 | 3 | `overlays/staging/observability/promtail` |
| `tempo` | `grafana/tempo` | 1.10.3 | 3 | `overlays/staging/observability/tempo` |

`prometheus` uses wave 2 because it installs the Prometheus Operator CRDs (ServiceMonitor, PrometheusRule, etc.), which must exist before Loki, Promtail and Tempo (wave 3) can be deployed.

Values file structure in the repository:
```
k8s/infrastructure/
├── base/observability/
│   ├── kube-prometheus-stack/values.yaml  ← common chart values
│   ├── loki/values.yaml
│   ├── promtail/values.yaml
│   └── tempo/values.yaml
└── overlays/staging/observability/
    ├── kube-prometheus-stack/
    │   ├── kustomization.yaml             ← declares helmChart with base + overlay values
    │   └── values.yaml                    ← staging overrides (resources, retention, disabled scrapers)
    ├── loki/
    │   ├── kustomization.yaml
    │   └── values.yaml                    ← SingleBinary, lokiCanary disabled
    ├── promtail/kustomization.yaml
    └── tempo/kustomization.yaml
```

---

## Prometheus

### ServiceMonitors — Scraping OpenPanel

OpenPanel component scraping is managed via **ServiceMonitor CRs** (Prometheus Operator), not via pod annotations. This provides better control, consistent labelling and clear visibility in the Prometheus UI.

All ServiceMonitors are in `k8s/apps/base/openpanel/servicemonitors.yaml` and carry the label `release: kube-prometheus-stack` so the Prometheus CR selects them.

| ServiceMonitor | Scrape Port | Key Metrics | Interval |
|---|---|---|---|
| `openpanel-api` | `:3000/metrics` | `http_request_duration_seconds{method,route,status_code}`, Node.js runtime | 15s |
| `postgres-exporter` | `:9187/metrics` | `pg_up`, connections, queries, locks | 30s |
| `redis-exporter` | `:9121/metrics` | `redis_up`, memory, commands/s | 30s |
| `clickhouse` | `:9363/metrics` | Native ClickHouse metrics (queries, merges, memory) | 30s |

Each ServiceMonitor includes a `relabelings` rule to copy the pod's `app` label into the Prometheus target labels, enabling queries such as `up{app="openpanel-api"}`.

### Exporter architecture (sidecars)

```
openpanel-api-blue-deployment
└── container: api              (:3000 — HTTP + /metrics prom-client)

redis-deployment
├── container: redis            (:6379)
└── container: redis-exporter   (:9121 — sidecar)

postgres-statefulset
├── container: postgres         (:5432)
└── container: postgres-exporter (:9187 — sidecar)

clickhouse-statefulset
└── container: clickhouse       (:9363 — native metrics via XML config)
```

### Active targets

```bash
# Verify all targets are UP in Prometheus
curl -s http://prometheus.local/api/v1/targets | \
  python3 -c "import json,sys; [print(t['labels']['job'], t['health']) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"
```

Expected active targets: `apiserver`, `coredns`, `kubelet`, `node-exporter`, `kube-state-metrics`, `kube-prometheus-stack-prometheus`, `kube-prometheus-stack-alertmanager`, `openpanel-api`, `postgres`, `redis`, `clickhouse`.

### Disabled scrapers in staging

To avoid false-positive alerts in Minikube (control-plane components not reachable from inside the cluster), the following scrapers are disabled in the staging overlay:

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
```

These must be enabled in production.

---

## Grafana

### Access

```bash
open http://grafana.local   # User: admin / Password: admin
```

### Automatically configured datasources

| Datasource | Internal URL | Correlation |
|---|---|---|
| Prometheus | `http://kube-prometheus-stack-prometheus.observability:9090` | — |
| Loki | `http://loki-gateway.observability.svc.cluster.local` | → Tempo (traceID regex) |
| Tempo | `http://tempo.observability.svc.cluster.local:3100` | → Loki (by job/namespace/pod tags) |

### Dashboards — Organised folders

#### Folder: Cluster

| Dashboard | grafana.com ID | Content |
|---|---|---|
| Kubernetes / Views / Pods | 15760 | Global cluster view: pods, nodes, namespaces |
| Node Exporter Full | 1860 | CPU, memory, disk, network per node |
| Kubernetes Cluster | 7249 | Resources per namespace |
| Kubernetes cluster monitoring | 3119 | Pod and container drill-down |

#### Folder: OpenPanel

| Dashboard | grafana.com ID | Content |
|---|---|---|
| OpenPanel API (custom JSON) | — | RED method: request rate, error rate, P50/P90/P99 latency, top routes, Node.js runtime, GC, event loop |
| PostgreSQL Database | 9628 | pg_up, connections, DB size, queries/s |
| Redis Dashboard | 11835 | redis_up, memory, commands/s, clients |
| ClickHouse | 14192 | Queries, merges, memory, uptime |
| Node.js App | 11159 | Standard prom-client metrics |

#### Built-in (General folder)

Kubernetes / API server, Compute Resources, Networking, Persistent Volumes, AlertManager, CoreDNS, Prometheus Overview, Node Exporter, USE Method.

### Dashboard sidecar

Any ConfigMap with label `grafana_dashboard: "1"` is auto-loaded as a dashboard. The folder is set via the `grafana_folder` annotation. Sidecar monitors all namespaces (`searchNamespace: ALL`).

---

## Loki + Promtail

**Promtail** is a DaemonSet running on every node that collects logs from all pods and ships them to **Loki**.

### Loki configuration (staging)

Deployed in **SingleBinary** mode with filesystem storage and in-memory ring configuration:

```yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  storage:
    type: filesystem
  structuredConfig:
    ingester:
      lifecycler:
        ring:
          kvstore:
            store: inmemory
    distributor:
      ring:
        kvstore:
          store: inmemory
lokiCanary:
  enabled: false
test:
  enabled: false
```

### Querying logs in Grafana (LogQL)

```logql
{namespace="openpanel", app="openpanel-api"}
{namespace="openpanel"} |= "error"
{namespace="openpanel", app="openpanel-worker"} | json | level="error"
```

---

## Tempo — Distributed Tracing

Tempo receives traces in **OTLP** format on port 4317 (gRPC).

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc.cluster.local:4317
```

---

## Alerts — Rules and AlertManager

### Configured alert rules

| Alert | Expression | Duration | Severity |
|---|---|---|---|
| `ServiceDown` | `up{job="openpanel-api", namespace="openpanel"} == 0` | 2 min | critical |
| `HighErrorRate` | HTTP 5xx rate / total > 5% | 5 min | critical |
| `APIHighLatency` | P99 latency > 2s | 5 min | warning |
| `NodeJSEventLoopLag` | `nodejs_eventloop_lag_p99_seconds > 0.5` | 5 min | warning |
| `HighMemoryUsage` | container memory / limit > 90% | 5 min | warning |
| `DatabaseDown` | `pg_up == 0 or redis_up == 0` | 1 min | critical |

### System alerts (expected, not errors)

| Alert | Meaning |
|---|---|
| `Watchdog` | Always-firing heartbeat. **If it disappears, the pipeline is broken.** |
| `InfoInhibitor` | Suppresses Info alerts when a Warning is active for the same alertname. |

### Verifying the alert pipeline

```bash
open http://prometheus.local/alerts   # Watchdog must show as Firing
open http://alertmanager.local        # Watchdog must appear here too
```

---

## Stack Verification

```bash
kubectl get pods -n observability
argocd app list | grep -E "prometheus|loki|promtail|tempo"
curl -s http://prometheus.local/api/v1/targets?state=active | \
  python3 -c "import json,sys; \
  [print(t['labels']['job'], t['health']) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"
kubectl exec -n observability loki-0 -- wget -qO- localhost:3100/ready
```
