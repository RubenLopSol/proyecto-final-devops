# Observability — Metrics, Logs and Traces

**Final Project — Master in DevOps & Cloud Computing**

---

## Observability Stack

The system implements the three pillars of observability:

| Pillar | Tool | Port | Description |
|---|---|---|---|
| **Metrics** | Prometheus | 9090 | Collects time-series metrics |
| **Logs** | Loki + Promtail | 3100 | Aggregates logs from all pods |
| **Traces** | Tempo | 3200 / 4317 | Distributed tracing (OTLP) |
| **Dashboards** | Grafana | 3000 | Unified visualization |

All components are deployed in the `observability` namespace using **official Helm charts** managed by ArgoCD.

---

## Prometheus

### Configuration

Prometheus scrapes the following targets:

| Target | Port | What it measures |
|---|---|---|
| `cadvisor` | 8080 | Container metrics (CPU, memory, network) |
| `node-exporter` | 9100 | Node metrics (CPU, memory, disk) |
| `redis_exporter` | 9121 | Redis metrics (commands/s, memory, clients) |
| `postgres_exporter` | 9187 | PostgreSQL metrics (connections, queries, size) |
| ClickHouse | 9363 | Native ClickHouse metrics (queries, rows, memory) |
| Kubernetes pods | — | Auto-discovery via annotations |

### Exporter Architecture

```
redis-deployment
├── container: redis         (port 6379)
└── container: redis_exporter (port 9121, sidecar)

postgres-statefulset
├── container: postgres        (port 5432)
└── container: postgres_exporter (port 9187, sidecar)

clickhouse-statefulset
└── container: clickhouse     (port 9363, native metrics via XML config)

node-exporter-daemonset       (port 9100, one pod per node)
```

### Verifying active targets

```bash
# Port-forward to Prometheus
kubectl port-forward svc/prometheus -n observability 9090:9090

# Access http://localhost:9090/targets
# All targets should be in "UP" state
```

![Prometheus — Active targets in UP state](../screenshots/prometheus-targets.png)

---

## Grafana

### Dashboard: OpenPanel K8s Monitoring

The `openpanel-k8s` dashboard (uid: `openpanel-k8s`) contains **18 panels** organized in rows:

#### Row: Kubernetes Resources

| Panel | Type | Metric |
|---|---|---|
| Memory Usage by Pod | Timeseries | `container_memory_working_set_bytes` |
| CPU Usage by Pod | Timeseries | `rate(container_cpu_usage_seconds_total[5m])` |
| Top 5 Pods by Memory | Stat | `topk(5, ...)` |
| Top 5 Pods by CPU | Stat | `topk(5, ...)` |

#### Row: Redis

| Panel | Type | Metric |
|---|---|---|
| Redis UP | Stat | `redis_up` |
| Redis Connected Clients | Stat | `redis_connected_clients` |
| Redis Used Memory | Stat | `redis_memory_used_bytes` |
| Redis Commands/sec | Timeseries | `rate(redis_commands_processed_total[5m])` |
| Redis Memory Over Time | Timeseries | `redis_memory_used_bytes` |

#### Row: PostgreSQL

| Panel | Type | Metric |
|---|---|---|
| PostgreSQL UP | Stat | `pg_up` |
| PostgreSQL DB Size | Stat | `pg_database_size_bytes` |
| PostgreSQL Rows Fetched/sec | Timeseries | `rate(pg_stat_database_tup_fetched[5m])` |

#### Row: Node

| Panel | Type | Metric |
|---|---|---|
| Node Disk Available | Stat | `node_filesystem_avail_bytes` |
| Node Disk Usage % | Timeseries | Disk free/total ratio |

![Grafana — OpenPanel K8s Monitoring Dashboard](../screenshots/grafana-dashboard.png)

---

### Dashboard Automation

Grafana is deployed via the `kube-prometheus-stack` chart. Datasources (Prometheus, Loki, Tempo) are configured automatically via the `additionalDataSources` field in `k8s/infrastructure/base/observability/kube-prometheus-stack/values.yaml`.

No manual action is required — when Grafana starts, the datasources appear automatically configured.

---

### Accessing Grafana

```bash
# Via Ingress (requires /etc/hosts configured)
# http://grafana.local

# Via port-forward
kubectl port-forward svc/kube-prometheus-stack-grafana -n observability 3000:3000
# http://localhost:3000
# User: admin / Password: admin (configurable in kube-prometheus-stack.yaml)
```

### Configured datasources

| Datasource | Internal URL | Type |
|---|---|---|
| Prometheus | `http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090` | prometheus |
| Loki | `http://loki-gateway.observability.svc.cluster.local` | loki |
| Tempo | `http://tempo.observability.svc.cluster.local:3100` | tempo |

---

## Loki + Promtail

**Promtail** is a DaemonSet that runs on each node, collects logs from all pods and sends them to **Loki**.

### Querying logs in Grafana (LogQL)

```logql
# API logs
{namespace="openpanel", app="openpanel-api"}

# Error logs in all pods
{namespace="openpanel"} |= "error"

# Worker logs filtered by level
{namespace="openpanel", app="openpanel-worker"} | json | level="error"

# Last 15 minutes of Postgres logs
{namespace="openpanel", app="postgres"} [15m]
```

---

## Tempo — Distributed Tracing

Tempo receives traces in **OTLP** (OpenTelemetry Protocol) format on port 4317 (gRPC).

To enable tracing in the application, configure the environment variable:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc.cluster.local:4317
```

Traces can be explored from Grafana using the Tempo datasource.

---

## Alerts — Prometheus AlertManager

Alerts follow this flow:

```
Prometheus evaluates rules every 30s
       │
       │ condition true for the configured duration
       ▼
Alert fires → sent to AlertManager
       │
       ▼
AlertManager groups alerts (by alertname + namespace + severity)
— waits 30s to batch related alerts (group_wait)
— suppresses warnings if a critical is already firing for the same alert (inhibit_rules)
       │
       ▼
Router sends to the configured receiver
— currently: 'null' receiver (no-op, for local demo)
— production: replace with Slack/email/PagerDuty
```

### Configured alert rules

Rules are defined in `k8s/infrastructure/base/observability/kube-prometheus-stack/values.yaml`:

| Alert | Condition | Duration | Severity |
|---|---|---|---|
| `ServiceDown` | `up{job=~".*openpanel.*"} == 0` | 2 min | critical |
| `HighErrorRate` | HTTP 5xx error rate > 5% | 5 min | critical |
| `HighMemoryUsage` | Memory usage > 90% of limit | 5 min | warning |
| `DatabaseDown` | `pg_up == 0 or redis_up == 0` | 1 min | critical |

### AlertManager — Routing and receivers

AlertManager is enabled with the following configuration:

- **group_by**: `alertname`, `namespace`, `severity` — groups related alerts
- **inhibit_rules**: if a `critical` fires for an alert, the `warning` for the same alertname in the same namespace is silenced
- **Current receiver**: `null` (local demo — alerts are evaluated and routed but not forwarded)

To add real notifications, replace the receiver in `k8s/infrastructure/base/observability/kube-prometheus-stack/values.yaml`:

```yaml
receivers:
  - name: 'slack'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/...'
        channel: '#alerts'
        send_resolved: true
```

### Verify AlertManager

```bash
kubectl port-forward svc/alertmanager-operated -n observability 9093:9093
# http://localhost:9093
```

![Prometheus — Active alert rules (http://prometheus.local/alerts)](../screenshots/grafana-alert-rules.png)

---

## Deployment — Helm charts via ArgoCD

The observability stack is managed by a **single ArgoCD Application** (`observability`) that renders all four charts using **kustomize + helmChartInflationGenerator**:

| Helm Chart | Version | Includes |
|---|---|---|
| `prometheus-community/kube-prometheus-stack` | 65.1.1 | Prometheus + Grafana + AlertManager + Node Exporter + kube-state-metrics |
| `grafana/loki` | 6.6.2 | Loki (single binary mode) |
| `grafana/promtail` | 6.16.4 | Promtail DaemonSet |
| `grafana/tempo` | 1.10.3 | Tempo |

Values for each chart live in `k8s/infrastructure/base/observability/<chart>/values.yaml` (shared base values) and `k8s/infrastructure/overlays/<env>/observability/<chart>/values.yaml` (per-environment overrides). ArgoCD calls `kustomize build --enable-helm` on `overlays/staging/observability/`, which aggregates all four chart subdirectories and renders each one inline.

Values structure:
```
base/observability/
├── kube-prometheus-stack/values.yaml   ← shared chart values
├── loki/values.yaml
├── promtail/values.yaml
└── tempo/values.yaml

overlays/staging/observability/
├── kube-prometheus-stack/values.yaml   ← staging-specific overrides
├── loki/values.yaml
├── promtail/values.yaml
└── tempo/values.yaml
```

---

## Stack Verification

```bash
# Verify all observability pods
kubectl get pods -n observability

# Verify that ArgoCD synced the observability app
kubectl get applications -n argocd | grep observability

# View Prometheus targets (all should be UP)
kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 9090:9090
# http://localhost:9090/targets

# View Promtail logs (verify it is collecting logs)
kubectl logs -n observability -l app.kubernetes.io/name=promtail --tail=20

# If a pod is in CrashLoopBackOff
kubectl describe pod -n observability <pod-name>
```
