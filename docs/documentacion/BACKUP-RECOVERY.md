# Backup y Recuperación — Velero + MinIO

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Estrategia de Backup

El sistema de backup está compuesto por dos componentes:

| Componente | Tecnología | Namespace | Rol |
|---|---|---|---|
| **MinIO** | Deployment + PVC | `backup` | Object storage S3-compatible (almacenamiento de backups) |
| **Velero** | DaemonSet + CRDs | `velero` | Orquestación de backups de Kubernetes |

---

## Schedules de Backup

Se configuran dos schedules automáticos en `k8s/base/backup/velero/schedule.yaml`:

### Backup Completo Diario

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-full-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"   # Todos los días a las 2:00 AM
  template:
    includedNamespaces:
      - openpanel
      - observability
    ttl: 720h0m0s          # Retención: 30 días
    storageLocation: default
```

### Backup de Bases de Datos Horario

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: hourly-database-backup
  namespace: velero
spec:
  schedule: "0 * * * *"   # Cada hora
  template:
    includedNamespaces:
      - openpanel
    labelSelector:
      matchLabels:
        backup: database   # Solo recursos con este label
    ttl: 24h0m0s           # Retención: 24 horas
    storageLocation: default
```

### Resumen de políticas

| Schedule | Frecuencia | Alcance | Retención |
|---|---|---|---|
| `daily-full-backup` | Diario (02:00 AM) | `openpanel` + `observability` | 30 días |
| `hourly-database-backup` | Cada hora | Pods con `backup: database` en `openpanel` | 24 horas |

---

## MinIO — Almacenamiento de Backups

MinIO actúa como un servidor S3 local donde Velero almacena los backups.

### Acceder a la consola MinIO

```bash
# Port-forward a MinIO
kubectl port-forward svc/minio -n backup 9000:9000 9001:9001
# Consola web: http://localhost:9001
```

### Verificar el bucket de backups

```bash
# Ver objetos almacenados en MinIO
kubectl exec -n backup deployment/minio -- \
  mc ls local/velero-backups/
```

---

## Script de Operaciones — `backup-restore.sh`

El repositorio incluye un script que simplifica las operaciones de backup y restauración:

```bash
# Ver ayuda y acciones disponibles
./scripts/backup-restore.sh help
```

### Acciones disponibles

| Comando | Descripción |
|---|---|
| `./scripts/backup-restore.sh backup [namespace]` | Backup completo de un namespace vía Velero (por defecto: `openpanel`) |
| `./scripts/backup-restore.sh backup-db` | Backup directo de PostgreSQL (`pg_dump`), snapshot de Redis (`SAVE`) y backup nativo de ClickHouse (`BACKUP DATABASE`) |
| `./scripts/backup-restore.sh restore <backup-name>` | Restaurar desde un backup Velero específico |
| `./scripts/backup-restore.sh list` | Listar todos los backups disponibles |

### Ejemplos de uso

```bash
# Backup completo del namespace openpanel
./scripts/backup-restore.sh backup openpanel

# Backup directo de PostgreSQL, Redis y ClickHouse (sin Velero)
./scripts/backup-restore.sh backup-db
# Genera: backup-postgres-<timestamp>.sql.gz en el directorio local
# Redis:   dispara un SAVE para forzar el RDB snapshot
# ClickHouse: BACKUP DATABASE openpanel TO File('backup-clickhouse-<timestamp>.zip')

# Listar backups disponibles
./scripts/backup-restore.sh list

# Restaurar desde un backup concreto
./scripts/backup-restore.sh restore manual-backup-20260318-143000
```

> El comando `backup-db` ejecuta `pg_dump` directamente sobre el pod de PostgreSQL, dispara el snapshot RDB de Redis, y usa el mecanismo nativo de ClickHouse (`BACKUP DATABASE ... TO File(...)`) precedido de `SYSTEM FLUSH LOGS` para garantizar la consistencia de los datos en memoria. Útil para backups puntuales rápidos sin depender de Velero.

---

## Comandos de Backup Manual (sin script)

### Crear un backup puntual

```bash
# Backup completo de openpanel
velero backup create backup-manual-$(date +%Y%m%d) \
  --include-namespaces openpanel \
  --namespace velero

# Backup solo de bases de datos
velero backup create db-backup-$(date +%Y%m%d-%H%M) \
  --include-namespaces openpanel \
  --selector backup=database \
  --namespace velero
```

### Ver backups disponibles

![Velero — Backups completados correctamente en MinIO](../screenshots/velero-backups-completed.png)

```bash
# Listar todos los backups
velero backup get --namespace velero

# Ver detalle de un backup específico
velero backup describe daily-full-backup-<timestamp> \
  --namespace velero

# Ver logs del backup
velero backup logs daily-full-backup-<timestamp> \
  --namespace velero
```

---

## Procedimiento de Restauración

### Restaurar desde el último backup completo

```bash
# 1. Ver backups disponibles
velero backup get --namespace velero

# 2. Crear la restauración
velero restore create \
  --from-backup daily-full-backup-<timestamp> \
  --namespace velero

# 3. Monitorizar el progreso
velero restore describe \
  daily-full-backup-<timestamp>-<restore-timestamp> \
  --namespace velero

# 4. Verificar que los pods han arrancado
kubectl get pods -n openpanel
```

### Restaurar solo las bases de datos

```bash
# Restaurar solo los recursos de base de datos
velero restore create \
  --from-backup hourly-database-backup-<timestamp> \
  --include-namespaces openpanel \
  --selector backup=database \
  --namespace velero
```

### Restaurar en un namespace diferente

```bash
# Restaurar openpanel en openpanel-restore para verificación
velero restore create \
  --from-backup daily-full-backup-<timestamp> \
  --namespace-mappings openpanel:openpanel-restore \
  --namespace velero
```

---

## Verificar el Sistema de Backup

```bash
# Ver estado de los schedules configurados
velero schedule get --namespace velero

# Verificar la ubicación de almacenamiento
velero backup-location get --namespace velero

# Verificar que MinIO está accesible
kubectl get pods -n backup
kubectl logs -n backup deployment/minio

# Ver el último backup completado
velero backup get --namespace velero | head -5
```

---

## Resolución de Problemas

| Problema | Diagnóstico | Solución |
|---|---|---|
| Backup en estado `PartiallyFailed` | `velero backup describe <name>` | Ver qué recursos fallaron y si tienen PVCs sin snapshot |
| Velero no puede conectar a MinIO | `kubectl logs -n velero deployment/velero` | Verificar credenciales y URL de MinIO en BackupStorageLocation |
| Schedule no ejecuta | `kubectl get schedule -n velero` | Verificar que `velero` namespace existe y el schedule está `Enabled` |
| Restauración incompleta | `velero restore describe <name>` | Puede ser que algunos PVs ya existan; usar `--existing-resource-policy update` |

---

## Notas de Implementación

> **IMPORTANTE:** El namespace de Velero es `velero`, no `backup`. El namespace `backup` contiene solo MinIO.
> Todos los comandos `velero` deben usar `--namespace velero`.

```bash
# CORRECTO
velero backup get --namespace velero
velero schedule get --namespace velero

# INCORRECTO (no funcionará)
velero backup get --namespace backup
```
