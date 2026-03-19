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
CD actualiza image tag en k8s/base/openpanel/
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
git log --oneline k8s/base/openpanel/ | head -5
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
| Secret no encontrado | `secret "X" not found` | Aplicar Sealed Secret: `kubectl apply -f k8s/argocd/sealed-secrets/` |
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
kubectl delete pod -n observability -l app=prometheus

# Verificar que el nuevo pod arranca correctamente
kubectl get pods -n observability -w
kubectl logs -n observability -l app=prometheus --tail=20
```

---

## 5. Alerta: Servicio Caído

**Alertas:** `APIDown`, `RedisDown`, `PostgreSQLDown`

```bash
# 1. Verificar el estado del pod
kubectl get pods -n openpanel -l app=<servicio>

# 2. Si el pod no existe o está en error:
kubectl describe pod -n openpanel -l app=<servicio>
kubectl logs -n openpanel -l app=<servicio> --previous

# 3. Forzar recreación del pod
kubectl delete pod -n openpanel -l app=<servicio>

# 4. Si es un StatefulSet (postgres, clickhouse):
kubectl rollout restart statefulset/<nombre> -n openpanel

# 5. Verificar en Prometheus que el target vuelve a UP
# http://localhost:9090/targets (tras port-forward)
```

---

## 6. Alerta: Alta Tasa de Errores HTTP

**Alerta:** `HighErrorRate` — más del 10% de peticiones retornan 5xx.

```bash
# 1. Ver logs de la API en tiempo real
kubectl logs -n openpanel -l app=openpanel-api -f --tail=100

# 2. Consulta en Prometheus para ver el detalle
# rate(http_requests_total{status=~"5.."}[5m])

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
# k8s/overlays/local/patches/resource-limits.yaml

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
# 1. Crear el nuevo Sealed Secret con el nuevo valor
kubectl create secret generic postgres-credentials \
  --from-literal=postgres-password=NuevaContraseña123 \
  --namespace openpanel \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets \
  --format yaml > k8s/argocd/sealed-secrets/postgres-credentials.yaml

# 2. Commitear y pushear
git add k8s/argocd/sealed-secrets/postgres-credentials.yaml
git commit -m "chore: rotate postgres credentials"
git push

# 3. ArgoCD aplicará el cambio automáticamente
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

# 2. Instalar Sealed Secrets PRIMERO
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
helm install sealed-secrets sealed-secrets/sealed-secrets -n sealed-secrets --create-namespace

# 3. Aplicar todos los Sealed Secrets
kubectl apply -f k8s/argocd/sealed-secrets/

# 4. Instalar ArgoCD (usa el script — incluye Ingress y modo HTTP)
./scripts/install-argocd.sh

# 5. Aplicar proyecto y aplicaciones ArgoCD
kubectl apply -f k8s/argocd/projects/
kubectl apply -f k8s/argocd/applications/

# 6. Esperar a que ArgoCD sincronice todo
kubectl get applications -n argocd -w

# 7. Instalar Velero
cat > velero-credentials <<EOF
[default]
aws_access_key_id=minioadmin
aws_secret_access_key=minio-secret-2024
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.backup.svc.cluster.local:9000
kubectl apply -f k8s/base/backup/velero/schedule.yaml

# 8. Configurar DNS local
echo "$(minikube ip -p openpanel) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" \
  | sudo tee -a /etc/hosts

# 9. Verificar estado final
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
