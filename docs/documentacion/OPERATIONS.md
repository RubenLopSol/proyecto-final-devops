# Operaciones — Comandos y Gestión del Sistema

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Scripts Disponibles

El repositorio incluye scripts en `scripts/` que automatizan las operaciones más habituales:

| Script | Uso |
|---|---|
| `./scripts/setup-minikube.sh` | Crear y configurar el clúster Minikube |
| `./scripts/install-argocd.sh` | Instalar ArgoCD y crear el Ingress |
| `./scripts/blue-green-switch.sh` | Conmutación Blue-Green de la API con health checks |
| `./scripts/backup-restore.sh` | Backup y restauración (Velero + pg_dump) |

---

## Arranque y Parada del Clúster

```bash
# Arrancar el clúster (perfil openpanel)
minikube start -p devops-cluster

# Parar el clúster (los datos persisten)
minikube stop -p devops-cluster

# Estado del clúster
minikube status -p devops-cluster
```

### Recuperación tras reinicio de minikube

Después de un `minikube start`, algunos pods pueden quedar en `CrashLoopBackOff` o `Init:Error`. El más habitual es `argocd-repo-server`:

```bash
# 1. Ver qué pods no están Running
kubectl get pods -A | grep -v "Running\|Completed"

# 2. Si argocd-repo-server está en Init:Error, borrarlo para que se recree limpio
kubectl delete pod -n argocd -l app.kubernetes.io/name=repo-server

# 3. Si sealed-secrets-controller está en CrashLoopBackOff
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets

# 4. Esperar ~30s y verificar que todos han recuperado
kubectl get pods -A | grep -v "Running\|Completed"
```

> **Nota:** El `argocd-repo-server` falla en el reinicio porque su init container `copyutil` intenta crear un enlace simbólico que ya existe del arranque anterior. Borrar el pod hace que Kubernetes lo recree con un estado limpio.

---

## Gestión del Clúster

```bash
# Estado general del clúster
minikube status
kubectl cluster-info
kubectl get nodes

# Ver todos los pods del sistema
kubectl get pods -A

# Ver pods por namespace
kubectl get pods -n openpanel
kubectl get pods -n observability
kubectl get pods -n argocd
kubectl get pods -n velero
kubectl get pods -n backup
```

---

## Gestión de la Aplicación (namespace: openpanel)

### Ver estado de los recursos

```bash
# Pods, services, deployments e ingress
kubectl get all -n openpanel

# Ver logs de un servicio
kubectl logs -n openpanel -l app=openpanel-api --tail=100 -f
kubectl logs -n openpanel -l app=openpanel-start --tail=100 -f
kubectl logs -n openpanel -l app=openpanel-worker --tail=100 -f

# Logs de las bases de datos
kubectl logs -n openpanel -l app=postgres --tail=50
kubectl logs -n openpanel -l app=redis --tail=50
kubectl logs -n openpanel -l app=clickhouse --tail=50
```

### Reiniciar un servicio

```bash
# Reinicio rolling (sin downtime)
kubectl rollout restart deployment/openpanel-api-blue -n openpanel
kubectl rollout restart deployment/openpanel-start -n openpanel
kubectl rollout restart deployment/openpanel-worker -n openpanel

# Verificar el rollout
kubectl rollout status deployment/openpanel-api-blue -n openpanel
```

### Escalar servicios

```bash
# Escalar la API Blue a 3 réplicas
kubectl scale deployment openpanel-api-blue -n openpanel --replicas=3

# Escalar el Worker
kubectl scale deployment openpanel-worker -n openpanel --replicas=2

# Ver el escalado en tiempo real
kubectl get pods -n openpanel -w
```

---

## Blue-Green — Conmutación de Tráfico API

### Con el script (recomendado)

```bash
# Detecta la versión activa, escala la nueva, verifica salud y conmuta con confirmación
./scripts/blue-green-switch.sh
```

Ver documentación completa del script en [BLUE-GREEN.md](BLUE-GREEN.md#script-de-conmutación----blue-green-switchsh).

### Manual

```bash
# Ver versión activa actualmente
kubectl get svc openpanel-api -n openpanel \
  -o jsonpath='{.spec.selector.version}'

# Conmutar a Green
kubectl patch svc openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"green"}}}'

# Rollback a Blue
kubectl patch svc openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"blue"}}}'

# Ver pods activos por versión
kubectl get pods -n openpanel -l version=blue
kubectl get pods -n openpanel -l version=green
```

---

## Observabilidad — Acceso a Herramientas

### Grafana

```bash
kubectl port-forward svc/grafana -n observability 3000:3000
# http://localhost:3000
# User: admin | Password: ver Secret grafana-admin-credentials
kubectl get secret grafana-admin-credentials -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### Prometheus

```bash
kubectl port-forward svc/prometheus -n observability 9090:9090
# http://localhost:9090
# Targets: http://localhost:9090/targets
# Alerts: http://localhost:9090/alerts
```

### ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# https://localhost:8080
# User: admin | Password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## ArgoCD — Gestión de Despliegues

> **Prerequisito:** hacer login con el CLI antes de usar los comandos `argocd`:
> ```bash
> kubectl port-forward svc/argocd-server -n argocd 8080:80 &
> argocd login localhost:8080 --insecure \
>   --username admin \
>   --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
>     -o jsonpath="{.data.password}" | base64 -d)
> ```

```bash
# Ver estado de todas las aplicaciones
kubectl get applications -n argocd
argocd app list

# Sincronizar manualmente una app
argocd app sync openpanel
argocd app sync observability
argocd app sync minio
argocd app sync velero
argocd app sync sealed-secrets
argocd app sync namespaces

# Ver diferencias entre Git y el clúster
argocd app diff openpanel

# Ver historial de despliegues
argocd app history openpanel

# Hacer rollback a una versión anterior
argocd app rollback openpanel <revision-id>

# Forzar sincronización completa
argocd app sync openpanel --force --prune
```

---

## Backups — Gestión con Velero

### Con el script (recomendado)

```bash
# Backup completo del namespace openpanel
./scripts/backup-restore.sh backup openpanel

# Backup directo de PostgreSQL y Redis (pg_dump + redis SAVE)
./scripts/backup-restore.sh backup-db

# Listar backups disponibles
./scripts/backup-restore.sh list

# Restaurar desde un backup
./scripts/backup-restore.sh restore <nombre-backup>
```

Ver documentación completa del script en [BACKUP-RECOVERY.md](BACKUP-RECOVERY.md#script-de-operaciones----backup-restoresh).

### Manual (comandos velero directos)

```bash
# Ver schedules configurados
velero schedule get --namespace velero

# Ver backups disponibles
velero backup get --namespace velero

# Crear backup manual
velero backup create backup-manual-$(date +%Y%m%d-%H%M) \
  --include-namespaces openpanel \
  --namespace velero

# Ver estado del backup
velero backup describe <nombre-backup> --namespace velero

# Restaurar desde un backup
velero restore create \
  --from-backup <nombre-backup> \
  --namespace velero
```

---

## Secrets — Gestión con Sealed Secrets

```bash
# Regenerar todos los secrets cifrados (tras rotar credenciales o recrear el clúster)
make reseal-secrets ENV=staging

# Rotar una credencial específica
make reseal-secrets ENV=staging POSTGRES_PASSWORD=nueva-pass

# Verificar que el controller está activo
kubectl get pods -n sealed-secrets

# Ver secrets descifrados en los namespaces
kubectl get secrets -n openpanel
kubectl get secrets -n observability
kubectl get secrets -n backup
```

---

## Acceso Directo a Bases de Datos

### PostgreSQL

```bash
# Obtener contraseña
kubectl get secret postgres-credentials -n openpanel \
  -o jsonpath='{.data.postgres-password}' | base64 -d

# Conectar vía psql
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -d openpanel
```

### Redis

```bash
# Conectar a Redis CLI
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=redis -o jsonpath='{.items[0].metadata.name}') \
  -c redis -- redis-cli

# Dentro de Redis CLI:
# INFO server
# DBSIZE
# LLEN bull:default:wait
```

### ClickHouse

```bash
# Conectar al cliente ClickHouse
kubectl exec -it -n openpanel \
  $(kubectl get pod -n openpanel -l app=clickhouse -o jsonpath='{.items[0].metadata.name}') \
  -- clickhouse-client

# Dentro del cliente:
# SHOW DATABASES;
# SELECT count() FROM openpanel.events;
```

---

## Monitorización de Recursos

```bash
# Uso de recursos por pod (requiere metrics-server)
kubectl top pods -n openpanel
kubectl top pods -n observability

# Uso de recursos por nodo
kubectl top nodes

# Ver PVCs y su estado
kubectl get pvc -A

# Ver PVs disponibles
kubectl get pv
```

---

## Troubleshooting Rápido

```bash
# Pod en CrashLoopBackOff — ver logs del contenedor fallido
kubectl logs -n <namespace> <pod-name> --previous

# Pod en Pending — ver eventos
kubectl describe pod -n <namespace> <pod-name>

# ImagePullBackOff — verificar que la imagen existe
kubectl get pod -n <namespace> <pod-name> -o jsonpath='{.spec.containers[0].image}'

# Ver todos los eventos del namespace (ordenados por fecha)
kubectl get events -n openpanel --sort-by=.metadata.creationTimestamp

# Describir un deployment para ver el estado completo
kubectl describe deployment openpanel-api-blue -n openpanel
```
