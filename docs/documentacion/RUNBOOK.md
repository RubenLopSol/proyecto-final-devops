# Runbook — Procedimientos Operacionales

**Proyecto Final — Master DevOps & Cloud Computing**

Este runbook recoge los procedimientos paso a paso para las situaciones más habituales en producción: despliegues, incidentes, alertas y mantenimiento.

---

## Índice

1. [Despliegue de nueva versión](#1-despliegue-de-nueva-versión)
2. [Rollback de emergencia](#2-rollback-de-emergencia)
3. [Pod en CrashLoopBackOff](#3-pod-en-crashloopbackoff)
4. [Prometheus no arranca (TSDB lock)](#4-prometheus-no-arranca-tsdb-lock)
5. [Alerta: servicio caído](#5-alerta-servicio-caído)
6. [Alerta: alta tasa de errores HTTP](#6-alerta-alta-tasa-de-errores-http)
7. [Alerta: alto uso de memoria](#7-alerta-alto-uso-de-memoria)
8. [Restaurar desde backup](#8-restaurar-desde-backup)
9. [Rotación de secrets](#9-rotación-de-secrets)
10. [Arrancar el clúster desde cero](#10-arrancar-el-clúster-desde-cero)

---

## 1. Despliegue de Nueva Versión

**Flujo normal (automático):**

```
Developer push a main
    ↓
CI ejecuta lint + build + push imagen
    ↓
CD actualiza image tag en k8s/apps/base/openpanel/
    ↓
ArgoCD detecta el cambio y despliega
    ↓
Nueva versión activa (rolling update)
```

**Verificar que el despliegue fue exitoso:**

```bash
# 1. Ver que el pipeline CI/CD está verde
gh run list --limit 5

# 2. Ver que ArgoCD está Synced
kubectl get application openpanel -n argocd \
  -o jsonpath='{.status.sync.status}'

# 3. Ver que los pods con la nueva imagen están Running
kubectl get pods -n openpanel
kubectl describe pod -n openpanel <pod-name> | grep Image:

# 4. Ver logs de la nueva versión (no debe haber errores)
kubectl logs -n openpanel -l app=openpanel-api --tail=50
```

---

## 2. Rollback de Emergencia

### Rollback via ArgoCD (recomendado)

```bash
# 1. Ver historial de la aplicación
argocd app history openpanel

# 2. Hacer rollback a la revisión anterior
argocd app rollback openpanel <revision-id>

# 3. Verificar que el rollback se aplicó
kubectl get pods -n openpanel
```

### Rollback Blue-Green (solo API, más rápido)

El script detecta la versión activa y puede revertir automáticamente:

```bash
# El script pregunta confirmación antes de conmutar — responder 'y'
./scripts/blue-green-switch.sh
```

O manualmente de forma inmediata:

```bash
# Conmutar el tráfico de vuelta a Blue instantáneamente
kubectl patch svc openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"blue"}}}'

# Verificar
kubectl get svc openpanel-api -n openpanel \
  -o jsonpath='{.spec.selector.version}'
# Debe devolver: blue
```

### Rollback via Git (GitOps)

```bash
# Revertir el último commit del CD (que actualizó el image tag)
git log --oneline k8s/apps/base/openpanel/ | head -5
git revert <commit-sha>
git push
# ArgoCD desplegará la versión anterior automáticamente
```

---

## 3. Pod en CrashLoopBackOff

```bash
# 1. Identificar el pod problemático
kubectl get pods -n openpanel

# 2. Ver los logs del intento fallido
kubectl logs -n openpanel <pod-name> --previous

# 3. Ver los eventos del pod (motivo del fallo)
kubectl describe pod -n openpanel <pod-name> | tail -20

# Causas comunes y soluciones:
```

| Causa | Síntoma en logs | Solución |
|---|---|---|
| Secret no encontrado | `secret "X" not found` | Reseal: `make sealed-secrets ENV=staging` o `argocd app sync sealed-secrets` |
| Variable de entorno faltante | `Error: missing env DATABASE_URL` | Verificar ConfigMap y Secrets |
| No puede conectar a la DB | `ECONNREFUSED :5432` | Verificar que PostgreSQL está Running y NetworkPolicy permite la conexión |
| OOMKilled | `OOMKilled` en reason | Aumentar memory limit en el patch de resource-limits |
| Error en la aplicación | Stack trace en logs | Revisar el código, hacer rollback si es necesario |

---

## 4. Prometheus No Arranca (TSDB Lock)

**Síntoma:** Prometheus en `CrashLoopBackOff` con error en logs:
```
opening storage failed: lock DB directory: resource temporarily unavailable
```

**Causa:** El proceso anterior de Prometheus no liberó el lock del directorio TSDB antes de que el nuevo pod intentara arrancarlo.

**Solución:**

```bash
# NO hacer rollout restart (empeora el problema)
# Eliminar el pod directamente para que Kubernetes lo recree limpio
kubectl delete pod -n observability -l app.kubernetes.io/name=prometheus

# Verificar que el nuevo pod arranca correctamente
kubectl get pods -n observability -w
kubectl logs -n observability -l app.kubernetes.io/name=prometheus --tail=20
```

---

## 5. Alerta: Servicio Caído

**Alerta:** `ServiceDown` — `up{job="openpanel-api",namespace="openpanel"} == 0` durante 2 minutos.

Los ServiceMonitors de Prometheus Operator controlan el scraping de todos los componentes de openpanel. Si un target cae:

```bash
# 1. Verificar targets en Prometheus
# http://prometheus.local/targets  (o con port-forward)
kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 9090:9090
# Abrir http://localhost:9090/targets y buscar el target caído

# 2. Verificar el estado del pod
kubectl get pods -n openpanel -l app=<servicio>

# 3. Si el pod no existe o está en error:
kubectl describe pod -n openpanel -l app=<servicio>
kubectl logs -n openpanel -l app=<servicio> --previous

# 4. Forzar recreación del pod
kubectl delete pod -n openpanel -l app=<servicio>

# 5. Si es un StatefulSet (postgres, clickhouse):
kubectl rollout restart statefulset/<nombre> -n openpanel

# 6. Verificar ServiceMonitor activo
kubectl get servicemonitor -n openpanel
kubectl describe servicemonitor openpanel-api -n openpanel
```

---

## 6. Alerta: Alta Tasa de Errores HTTP

**Alerta:** `HighErrorRate` — más del 10% de peticiones retornan 5xx durante 5 minutos.

La métrica proviene del ServiceMonitor de la API: `http_request_duration_seconds_count{status_code=~"5..",job="openpanel-api"}`.

```bash
# 1. Ver logs de la API en tiempo real
kubectl logs -n openpanel -l app=openpanel-api -f --tail=100

# 2. Consulta en Prometheus para ver el detalle por ruta
rate(http_request_duration_seconds_count{status_code=~"5..",job="openpanel-api"}[5m])

# Ver la tasa de error como porcentaje
sum(rate(http_request_duration_seconds_count{status_code=~"5..",job="openpanel-api"}[5m]))
/
sum(rate(http_request_duration_seconds_count{job="openpanel-api"}[5m]))

# 3. Ver si hay errores de conexión a bases de datos
kubectl logs -n openpanel -l app=openpanel-api | grep -i "error\|ECONNREFUSED\|timeout"

# 4. Verificar estado de las bases de datos
kubectl get pods -n openpanel -l app=postgres
kubectl get pods -n openpanel -l app=redis
kubectl get pods -n openpanel -l app=clickhouse

# 5. Si el problema persiste, considerar rollback
argocd app rollback openpanel <revision-anterior>
```

---

## 6b. Alerta: Alta Latencia de API

**Alerta:** `APIHighLatency` — P99 de latencia supera 2 segundos durante 5 minutos.

```bash
# 1. Consulta PromQL para ver la latencia actual
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{job="openpanel-api"}[5m])) by (le, route)
)

# 2. Ver las rutas más lentas en el dashboard de Grafana
# Dashboard: OpenPanel API → TOP 10 Slowest Routes

# 3. Verificar carga en las bases de datos
kubectl top pods -n openpanel
kubectl exec -it -n openpanel <postgres-pod> -- psql -U postgres -d openpanel \
  -c "SELECT query, calls, mean_exec_time FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 5;"

# 4. Si hay degradación sostenida, considerar rollback o escalar
kubectl scale deployment openpanel-api-blue -n openpanel --replicas=2
```

---

## 6c. Alerta: Event Loop Lag de Node.js

**Alerta:** `NodeJSEventLoopLag` — P99 del event loop lag supera 500ms durante 5 minutos.

Indica que el proceso Node.js está bloqueado o sobrecargado.

```bash
# 1. Ver el event loop lag actual
histogram_quantile(0.99, sum(rate(nodejs_eventloop_lag_seconds_bucket{job="openpanel-api"}[5m])) by (le))

# 2. Ver uso de CPU del pod
kubectl top pods -n openpanel -l app=openpanel-api

# 3. Ver si hay tareas de worker acumuladas
kubectl exec -it -n openpanel <redis-pod> -c redis -- redis-cli LLEN bull:default:wait

# 4. Reiniciar el pod si el lag es severo
kubectl delete pod -n openpanel -l app=openpanel-api,version=blue
```

---

## 7. Alerta: Alto Uso de Memoria

**Alerta:** `HighMemoryUsage` — un pod supera los 900MB de memoria.

```bash
# 1. Identificar qué pod tiene alto uso
kubectl top pods -n openpanel
kubectl top pods -n observability

# 2. Ver los límites configurados
kubectl describe pod -n openpanel <pod-name> | grep -A4 "Limits:"

# 3. Si el pod está siendo OOMKilled frecuentemente,
#    aumentar el límite de memoria en el patch:
# k8s/apps/overlays/staging/patches/api-blue.yaml (o start.yaml / worker.yaml según el pod)

# 4. Reiniciar el pod para liberar memoria inmediatamente
kubectl delete pod -n openpanel <pod-name>

# 5. Investigar la causa en Grafana
# Dashboard: OpenPanel K8s Monitoring → Memory Usage by Pod
```

---

## 8. Restaurar desde Backup

**Opción rápida con el script:**

```bash
# Listar backups disponibles
./scripts/backup-restore.sh list

# Restaurar desde un backup
./scripts/backup-restore.sh restore daily-full-backup-<timestamp>
```

**Procedimiento completo (manual):**

```bash
# 1. Ver backups disponibles
velero backup get --namespace velero

# 2. Elegir el backup más reciente válido
# Los backups se nombran: daily-full-backup-<timestamp>

# 3. Escalar los deployments a 0 para evitar conflictos
kubectl scale deployment --all -n openpanel --replicas=0

# 4. Iniciar la restauración
velero restore create \
  --from-backup daily-full-backup-<timestamp> \
  --namespace velero

# 5. Monitorizar el progreso
velero restore describe \
  daily-full-backup-<timestamp>-<restore-ts> \
  --namespace velero

# 6. Esperar a que la restauración complete (status: Completed)
velero restore get --namespace velero

# 7. Verificar que los pods arrancan correctamente
kubectl get pods -n openpanel -w

# 8. Validar datos en la base de datos
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -d openpanel -c "SELECT count(*) FROM users;"
```

---

## 9. Rotación de Secrets

Cuando es necesario cambiar una contraseña o token:

```bash
# 1. Regenerar secrets.yaml con la nueva credencial (el resto usa los valores del .secrets)
make reseal-secrets ENV=staging POSTGRES_PASSWORD=NuevaContraseña123

# 2. Commitear y pushear el archivo cifrado (es seguro)
git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
git commit -m "chore: rotate postgres credentials"
git push

# 3. ArgoCD (app sealed-secrets) aplica el cambio automáticamente.
# El controller crea el nuevo Secret con la contraseña actualizada.

# 4. Reiniciar los pods que usan el secret para que tomen el nuevo valor
kubectl rollout restart deployment/openpanel-api-blue -n openpanel
kubectl rollout restart deployment/openpanel-worker -n openpanel

# 5. Verificar que los pods arrancan con las nuevas credenciales
kubectl logs -n openpanel -l app=openpanel-api --tail=30
```

---

## 10. Arrancar el Clúster desde Cero

Procedimiento completo cuando el clúster se ha eliminado o es un entorno nuevo:

```bash
# 1. Crear clúster Minikube (usa el script)
./scripts/setup-minikube.sh

# 2. Instalar Sealed Secrets PRIMERO (controller + reseal + aplicar secrets)
make sealed-secrets ENV=staging
# Si tienes backup de la clave RSA del clúster anterior, restáurala primero:
# make restore-sealing-key

# 3. Instalar ArgoCD (usa el script — incluye Ingress y modo HTTP)
./scripts/install-argocd.sh
# El script aplica el AppProject y el bootstrap automáticamente.
# ArgoCD sincronizará openpanel, observability, minio, velero, sealed-secrets, namespaces.

# 4. Esperar a que ArgoCD sincronice todo
kubectl get applications -n argocd -w

# 5. Instalar el servidor Velero (manual — gestiona los backups)
cat > velero-credentials <<EOF
[default]
aws_access_key_id=$(grep MINIO_USER .secrets | cut -d= -f2)
aws_secret_access_key=$(grep MINIO_PASSWORD .secrets | cut -d= -f2)
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --namespace velero \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000

rm velero-credentials  # no dejar en disco

# 6. Configurar DNS local
echo "$(minikube ip -p devops-cluster) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
  | sudo tee -a /etc/hosts

# 7. Verificar estado final
kubectl get pods -A
kubectl get applications -n argocd
velero schedule get --namespace velero
```

---

## Checklist de Salud del Sistema

Ejecutar periódicamente para verificar el estado general:

```bash
echo "=== Pods en error ==="
kubectl get pods -A | grep -v Running | grep -v Completed | grep -v NAME

echo "=== ArgoCD sync status ==="
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

echo "=== Backups recientes ==="
velero backup get --namespace velero | head -5

echo "=== PVCs ==="
kubectl get pvc -A

echo "=== Uso de recursos ==="
kubectl top nodes
```
