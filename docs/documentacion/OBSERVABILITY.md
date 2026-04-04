# Observabilidad — Métricas, Logs y Trazas

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Stack de Observabilidad

El sistema implementa los tres pilares de la observabilidad:

| Pilar | Herramienta | Puerto | Descripción |
|---|---|---|---|
| **Métricas** | Prometheus | 9090 | Recopila métricas de series temporales vía ServiceMonitors |
| **Logs** | Loki + Promtail | 3100 | Agrega logs de todos los pods del clúster |
| **Trazas** | Tempo | 3200 / 4317 | Tracing distribuido (OTLP) |
| **Dashboards** | Grafana | 3000 | Visualización unificada con datasources correlacionados |
| **Alertas** | AlertManager | 9093 | Enrutamiento y supresión de alertas |

Todos los componentes se despliegan en el namespace `observability` mediante **Helm charts oficiales** gestionados por **4 aplicaciones ArgoCD independientes**.

### URLs de acceso (staging / Minikube)

| Servicio | URL | Credenciales |
|---|---|---|
| Grafana | http://grafana.local | admin / admin |
| Prometheus | http://prometheus.local | — |
| AlertManager | http://alertmanager.local | — |

> Credenciales de Grafana: secret `grafana-admin-credentials` en el namespace `observability`.
> Recuperar con: `kubectl get secret grafana-admin-credentials -n observability -o jsonpath='{.data.admin-password}' | base64 -d`

---

## Despliegue — 4 aplicaciones ArgoCD independientes

El stack de observabilidad está dividido en **4 ArgoCD Applications independientes**, cada una gestionando un único Helm chart. Esto permite sincronizar o depurar un componente sin afectar a los demás.

| App ArgoCD | Chart | Versión | Sync Wave | Path |
|---|---|---|---|---|
| `prometheus` | `kube-prometheus-stack` | 65.1.1 | 2 | `overlays/staging/observability/kube-prometheus-stack` |
| `loki` | `grafana/loki` | 6.6.2 | 3 | `overlays/staging/observability/loki` |
| `promtail` | `grafana/promtail` | 6.16.4 | 3 | `overlays/staging/observability/promtail` |
| `tempo` | `grafana/tempo` | 1.10.3 | 3 | `overlays/staging/observability/tempo` |

`prometheus` usa wave 2 porque instala los CRDs de Prometheus Operator (ServiceMonitor, PrometheusRule, etc.), que deben existir antes de que Loki, Promtail y Tempo (wave 3) puedan desplegarse.

Estructura de values en el repositorio:
```
k8s/infrastructure/
├── base/observability/
│   ├── kube-prometheus-stack/values.yaml  ← valores comunes
│   ├── loki/values.yaml
│   ├── promtail/values.yaml
│   └── tempo/values.yaml
└── overlays/staging/observability/
    ├── kube-prometheus-stack/
    │   ├── kustomization.yaml             ← declara el helmChart con base + overlay values
    │   └── values.yaml                    ← overrides de staging (recursos, retención, scrapers desactivados)
    ├── loki/
    │   ├── kustomization.yaml
    │   └── values.yaml                    ← SingleBinary, lokiCanary desactivado
    ├── promtail/kustomization.yaml
    └── tempo/kustomization.yaml
```

---

## Prometheus

### ServiceMonitors — Scraping de OpenPanel

El scraping de los componentes de OpenPanel se gestiona mediante **ServiceMonitor CRs** (Prometheus Operator), no via annotations de pod. Esto garantiza mayor control, etiquetado consistente y visibilidad clara en la UI de Prometheus.

Todos los ServiceMonitors están en `k8s/apps/base/openpanel/servicemonitors.yaml` y llevan la etiqueta `release: kube-prometheus-stack` para que el Prometheus CR los seleccione.

| ServiceMonitor | Puerto de scraping | Métrica principal | Intervalo |
|---|---|---|---|
| `openpanel-api` | `:3000/metrics` | `http_request_duration_seconds{method,route,status_code}`, Node.js runtime | 15s |
| `postgres-exporter` | `:9187/metrics` | `pg_up`, conexiones, queries, locks | 30s |
| `redis-exporter` | `:9121/metrics` | `redis_up`, memoria, comandos/s | 30s |
| `clickhouse` | `:9363/metrics` | Métricas nativas ClickHouse (queries, merges, memoria) | 30s |

Cada ServiceMonitor incluye una regla `relabeling` para copiar la etiqueta `app` del pod al target de Prometheus, habilitando consultas como `up{app="openpanel-api"}`.

### Arquitectura de exporters (sidecars)

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
└── container: clickhouse       (:9363 — métricas nativas via config XML)
```

### Targets activos

```bash
# Verificar todos los targets UP en Prometheus
curl -s http://prometheus.local/api/v1/targets | \
  python3 -c "import json,sys; [print(t['labels']['job'], t['health']) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"
```

Targets activos esperados: `apiserver`, `coredns`, `kubelet`, `node-exporter`, `kube-state-metrics`, `kube-prometheus-stack-prometheus`, `kube-prometheus-stack-alertmanager`, `openpanel-api`, `postgres`, `redis`, `clickhouse`.

### Scrapers desactivados en staging

Para evitar alertas falsas en Minikube (componentes de control plane no accesibles desde dentro del clúster), los siguientes scrapers están desactivados en el overlay de staging:

```yaml
# k8s/infrastructure/overlays/staging/observability/kube-prometheus-stack/values.yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false
```

Estos deben estar habilitados en producción.

---

## Grafana

### Acceso

```bash
# Via Ingress
open http://grafana.local
# Usuario: admin / Password: admin
```

### Datasources configurados automáticamente

| Datasource | URL interna | Correlación |
|---|---|---|
| Prometheus | `http://kube-prometheus-stack-prometheus.observability:9090` | — |
| Loki | `http://loki-gateway.observability.svc.cluster.local` | → Tempo (traceID regex) |
| Tempo | `http://tempo.observability.svc.cluster.local:3100` | → Loki (por tags job/namespace/pod) |

Los datasources se configuran automáticamente via `additionalDataSources` en los values del chart. No se requiere ninguna acción manual.

### Dashboards — Carpetas organizadas

Grafana incluye dashboards importados automáticamente desde grafana.com al iniciar el pod (via `grafana.dashboards` en values) y los dashboards built-in del chart.

#### Carpeta: Cluster

| Dashboard | grafana.com ID | Contenido |
|---|---|---|
| Kubernetes / Views / Pods | 15760 | Vista global del clúster: pods, nodos, namespaces |
| Node Exporter Full | 1860 | CPU, memoria, disco, red por nodo |
| Kubernetes Cluster | 7249 | Recursos por namespace |
| Kubernetes cluster monitoring | 3119 | Pod y container drill-down |

#### Carpeta: OpenPanel

| Dashboard | grafana.com ID | Contenido |
|---|---|---|
| OpenPanel API (custom) | — | RED method: request rate, error rate, latencia P50/P90/P99, top routes, Node.js runtime, GC, event loop |
| PostgreSQL Database | 9628 | pg_up, conexiones, tamaño BD, queries/s |
| Redis Dashboard | 11835 | redis_up, memoria, comandos/s, clientes |
| ClickHouse | 14192 | Queries, merges, memoria, uptime |
| Node.js App | 11159 | Métricas prom-client estándar |

#### Built-in del chart (carpeta General)

Kubernetes / API server, Compute Resources (Cluster/Namespace/Pod/Workload), Networking, Persistent Volumes, AlertManager, CoreDNS, Prometheus Overview, Node Exporter, USE Method.

### Sidecar de dashboards

El sidecar de Grafana monitoriza todos los namespaces en busca de ConfigMaps con la etiqueta `grafana_dashboard: "1"`. Cualquier ConfigMap con ese label se carga automáticamente como dashboard en la carpeta indicada por la anotación `grafana_folder`.

```yaml
sidecar:
  dashboards:
    enabled: true
    searchNamespace: ALL
    label: grafana_dashboard
    labelValue: "1"
```

---

## Loki + Promtail

**Promtail** es un DaemonSet que se ejecuta en cada nodo, recopila los logs de todos los pods y los envía a **Loki**.

### Configuración de Loki (staging)

Loki se despliega en modo **SingleBinary** (todos los componentes en un único proceso) con almacenamiento en filesystem y configuración de rings en memoria para evitar dependencias de red internas:

```yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  storage:
    type: filesystem
  structuredConfig:          # override profundo sobre la config generada por el chart
    ingester:
      lifecycler:
        ring:
          kvstore:
            store: inmemory  # evita deadlocks de memberlist en pod único
    distributor:
      ring:
        kvstore:
          store: inmemory
lokiCanary:
  enabled: false             # desactivado para reducir carga en staging
test:
  enabled: false
```

### Consultar logs en Grafana (LogQL)

```logql
# Logs de la API
{namespace="openpanel", app="openpanel-api"}

# Errores en todos los pods de openpanel
{namespace="openpanel"} |= "error"

# Logs del worker filtrados por nivel
{namespace="openpanel", app="openpanel-worker"} | json | level="error"

# Logs de Postgres de los últimos 15 minutos
{namespace="openpanel", app="postgres"} [15m]
```

---

## Tempo — Tracing Distribuido

Tempo recibe trazas en formato **OTLP** (OpenTelemetry Protocol) en el puerto 4317 (gRPC).

Para habilitar tracing en la aplicación, configurar la variable de entorno:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc.cluster.local:4317
```

Grafana enlaza trazas de Tempo con logs de Loki cuando las trazas incluyen el campo `traceID` en los logs.

---

## Alertas — Reglas y AlertManager

### Reglas de alerta configuradas

Definidas en `additionalPrometheusRulesMap` en `k8s/infrastructure/base/observability/kube-prometheus-stack/values.yaml`:

| Alerta | Expresión | Duración | Severidad |
|---|---|---|---|
| `ServiceDown` | `up{job="openpanel-api", namespace="openpanel"} == 0` | 2 min | critical |
| `HighErrorRate` | `rate(http_request_duration_seconds_count{status_code=~"5.."}) / rate(...total) > 0.05` | 5 min | critical |
| `APIHighLatency` | `histogram_quantile(0.99, ...) > 2s` | 5 min | warning |
| `NodeJSEventLoopLag` | `nodejs_eventloop_lag_p99_seconds > 0.5` | 5 min | warning |
| `HighMemoryUsage` | `container_memory_usage_bytes / container_spec_memory_limit_bytes > 0.9` | 5 min | warning |
| `DatabaseDown` | `pg_up == 0 or redis_up == 0` | 1 min | critical |

### Alertas del sistema (esperadas, no son errores)

| Alerta | Significado |
|---|---|
| `Watchdog` | Latido permanente — confirma que el pipeline Prometheus→AlertManager funciona. **Si desaparece, el pipeline está roto.** |
| `InfoInhibitor` | Suprime alertas de nivel Info cuando hay un Warning activo para el mismo alertname. |

### AlertManager — Routing

```
Prometheus evalúa reglas cada 30s
       │ condición verdadera durante el tiempo configurado
       ▼
Alerta se envía a AlertManager
       │
       ▼
Agrupa por (alertname, namespace, severity)
group_wait: 30s → group_interval: 5m → repeat_interval: 12h
       │
       ▼
inhibit_rules: si hay critical, suprime warning del mismo alertname+namespace
       │
       ▼
Receiver: 'null' (staging — alertas evaluadas pero no enviadas)
          → producción: reemplazar con Slack/PagerDuty/email
```

Para producción, reemplazar el receiver en values.yaml:

```yaml
receivers:
  - name: 'slack'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/...'
        channel: '#alerts'
        send_resolved: true
```

### Verificar el pipeline de alertas

```bash
# 1. Confirmar que Watchdog está disparándose (debe estar en Firing)
open http://prometheus.local/alerts

# 2. Confirmar que Watchdog llega a AlertManager
open http://alertmanager.local

# 3. Disparar una alerta de prueba manualmente
amtool alert add alertname=TestAlert severity=critical \
  --alertmanager.url=http://alertmanager.local
```

---

## Verificación del Stack

```bash
# Verificar todos los pods de observabilidad Running
kubectl get pods -n observability

# Estado de los 4 apps ArgoCD de observabilidad
argocd app list | grep -E "prometheus|loki|promtail|tempo"

# Targets activos en Prometheus (todos deben ser UP)
curl -s http://prometheus.local/api/v1/targets?state=active | \
  python3 -c "import json,sys; \
  [print(t['labels']['job'], t['health']) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"

# Test de scraping de la API (debe devolver datos)
# Pegar en http://prometheus.local/graph:
# rate(http_request_duration_seconds_count{job="openpanel-api"}[1m])

# Logs de Promtail (verificar recolección)
kubectl logs -n observability -l app.kubernetes.io/name=promtail --tail=20

# Verificar Loki ready
kubectl exec -n observability loki-0 -- wget -qO- localhost:3100/ready
```
