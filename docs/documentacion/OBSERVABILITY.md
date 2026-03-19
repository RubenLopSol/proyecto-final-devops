# Observabilidad — Métricas, Logs y Trazas

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Stack de Observabilidad

El sistema implementa los tres pilares de la observabilidad:

| Pilar | Herramienta | Puerto | Descripción |
|---|---|---|---|
| **Métricas** | Prometheus | 9090 | Recopila métricas de series temporales |
| **Logs** | Loki + Promtail | 3100 | Agrega logs de todos los pods |
| **Trazas** | Tempo | 3200 / 4317 | Tracing distribuido (OTLP) |
| **Dashboards** | Grafana | 3000 | Visualización unificada |

Todos los componentes se despliegan en el namespace `observability`.

---

## Prometheus

### Configuración

Prometheus scrape los siguientes targets:

| Target | Puerto | Qué mide |
|---|---|---|
| `cadvisor` | 8080 | Métricas de contenedores (CPU, memoria, red) |
| `node-exporter` | 9100 | Métricas del nodo (CPU, memoria, disco) |
| `redis_exporter` | 9121 | Métricas de Redis (comandos/s, memoria, clientes) |
| `postgres_exporter` | 9187 | Métricas de PostgreSQL (conexiones, queries, tamaño) |
| ClickHouse | 9363 | Métricas nativas de ClickHouse (queries, rows, memoria) |
| Kubernetes pods | — | Autodescubrimiento vía annotations |

### Arquitectura de Exporters

```
redis-deployment
├── container: redis         (puerto 6379)
└── container: redis_exporter (puerto 9121, sidecar)

postgres-statefulset
├── container: postgres        (puerto 5432)
└── container: postgres_exporter (puerto 9187, sidecar)

clickhouse-statefulset
└── container: clickhouse     (puerto 9363, métricas nativas via XML config)

node-exporter-daemonset       (puerto 9100, un pod por nodo)
```

### Verificar targets activos

```bash
# Port-forward a Prometheus
kubectl port-forward svc/prometheus -n observability 9090:9090

# Acceder a http://localhost:9090/targets
# Todos los targets deben estar en estado "UP"
```

![Prometheus — Targets activos en estado UP](../screenshots/prometheus-targets.png)

---

## Grafana

### Dashboard: OpenPanel K8s Monitoring

El dashboard `openpanel-k8s` (uid: `openpanel-k8s`) contiene **18 paneles** organizados en filas:

#### Fila: Kubernetes Resources

| Panel | Tipo | Métrica |
|---|---|---|
| Memory Usage by Pod | Timeseries | `container_memory_working_set_bytes` |
| CPU Usage by Pod | Timeseries | `rate(container_cpu_usage_seconds_total[5m])` |
| Top 5 Pods by Memory | Stat | `topk(5, ...)` |
| Top 5 Pods by CPU | Stat | `topk(5, ...)` |

#### Fila: Redis

| Panel | Tipo | Métrica |
|---|---|---|
| Redis UP | Stat | `redis_up` |
| Redis Connected Clients | Stat | `redis_connected_clients` |
| Redis Used Memory | Stat | `redis_memory_used_bytes` |
| Redis Commands/sec | Timeseries | `rate(redis_commands_processed_total[5m])` |
| Redis Memory Over Time | Timeseries | `redis_memory_used_bytes` |

#### Fila: PostgreSQL

| Panel | Tipo | Métrica |
|---|---|---|
| PostgreSQL UP | Stat | `pg_up` |
| PostgreSQL DB Size | Stat | `pg_database_size_bytes` |
| PostgreSQL Rows Fetched/sec | Timeseries | `rate(pg_stat_database_tup_fetched[5m])` |

#### Fila: Node

| Panel | Tipo | Métrica |
|---|---|---|
| Node Disk Available | Stat | `node_filesystem_avail_bytes` |
| Node Disk Usage % | Timeseries | Disk free/total ratio |

![Grafana — Dashboard OpenPanel K8s Monitoring](../screenshots/grafana-dashboard.png)

---

### Automatización del Dashboard

El dashboard se aprovisiona automáticamente desde ConfigMaps montados en el deployment de Grafana:

```yaml
volumes:
  - name: datasources        # grafana-datasources ConfigMap
  - name: dashboard-provisioning  # grafana-dashboard-provisioning ConfigMap
  - name: dashboard-openpanel     # grafana-dashboard-openpanel ConfigMap (el JSON)
  - name: data               # PVC grafana-data (persistencia)
```

El dashboard se recarga cada **30 segundos** (`updateIntervalSeconds: 30` en el provisioner).

No se requiere ninguna acción manual — al arrancar Grafana, el dashboard aparece automáticamente.

---

### Acceder a Grafana

```bash
# Via Ingress (requiere /etc/hosts configurado)
# http://grafana.local

# Via port-forward
kubectl port-forward svc/grafana -n observability 3000:3000
# http://localhost:3000
# Usuario: admin (desde Secret grafana-admin-credentials)
```

### Datasources configurados

| Datasource | URL interna | Tipo |
|---|---|---|
| Prometheus | `http://prometheus.observability.svc.cluster.local:9090` | prometheus |
| Loki | `http://loki.observability.svc.cluster.local:3100` | loki |
| Tempo | `http://tempo.observability.svc.cluster.local:3200` | tempo |

---

## Loki + Promtail

**Promtail** es un DaemonSet que se ejecuta en cada nodo, recopila los logs de todos los pods y los envía a **Loki**.

### Consultar logs en Grafana (LogQL)

```logql
# Logs de la API
{namespace="openpanel", app="openpanel-api"}

# Logs de error en todos los pods
{namespace="openpanel"} |= "error"

# Logs del worker con filtro por nivel
{namespace="openpanel", app="openpanel-worker"} | json | level="error"

# Logs de los últimos 15 minutos de Postgres
{namespace="openpanel", app="postgres"} [15m]
```

---

## Tempo — Tracing Distribuido

Tempo recibe trazas en formato **OTLP** (OpenTelemetry Protocol) en el puerto 4317 (gRPC).

Para habilitar tracing en la aplicación, configurar la variable de entorno:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc.cluster.local:4317
```

Las trazas se pueden explorar desde Grafana usando el datasource Tempo.

---

## Alertas — Prometheus Alertmanager

Las alertas se definen en el ConfigMap de Prometheus. Ejemplos de reglas:

```yaml
groups:
  - name: openpanel
    rules:
      # API caída
      - alert: APIDown
        expr: up{job="openpanel-api"} == 0
        for: 1m
        labels:
          severity: critical

      # Redis caído
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        labels:
          severity: critical

      # PostgreSQL caído
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical

      # Alta tasa de errores HTTP
      - alert: HighErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.1
        for: 5m
        labels:
          severity: warning

      # Pod con alto uso de memoria
      - alert: HighMemoryUsage
        expr: container_memory_working_set_bytes > 900000000
        for: 5m
        labels:
          severity: warning
```

![Prometheus — Reglas de alerta activas (http://prometheus.local/alerts)](../screenshots/grafana-alert-rules.png)

---

## Verificación del Stack

```bash
# Verificar todos los pods de observabilidad
kubectl get pods -n observability

# Ver targets de Prometheus (todos deben ser UP)
kubectl port-forward svc/prometheus -n observability 9090:9090
# http://localhost:9090/targets

# Ver logs de Promtail (verificar que recopila logs)
kubectl logs -n observability -l app=promtail --tail=20

# Verificar que Grafana cargó los datasources
kubectl logs -n observability -l app=grafana | grep -i datasource

# Si Prometheus está en CrashLoopBackOff por lock de TSDB
kubectl delete pod -n observability -l app=prometheus
```
