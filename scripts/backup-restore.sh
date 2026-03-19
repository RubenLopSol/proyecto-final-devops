#!/bin/bash
set -euo pipefail

# =============================================================================
# Backup and Restore operations for OpenPanel
# =============================================================================

ACTION="${1:-help}"
NAMESPACE="${2:-openpanel}"
BACKUP_NAME="manual-backup-$(date +%Y%m%d-%H%M%S)"

case "${ACTION}" in

  backup)
    echo "=== Creating backup: ${BACKUP_NAME} ==="
    velero backup create "${BACKUP_NAME}" \
      --include-namespaces "${NAMESPACE}" \
      --wait
    echo "Backup created: ${BACKUP_NAME}"
    velero backup describe "${BACKUP_NAME}"
    ;;

  backup-db)
    echo "=== Creating database backup ==="

    # PostgreSQL
    echo "--- PostgreSQL backup ---"
    PG_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=postgres -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n "${NAMESPACE}" "${PG_POD}" -- pg_dump -U openpanel openpanel | gzip > "backup-postgres-$(date +%Y%m%d-%H%M%S).sql.gz"
    echo "PostgreSQL backup saved."

    # Redis
    echo "--- Redis backup ---"
    REDIS_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=redis -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli SAVE
    echo "Redis RDB snapshot triggered."

    # ClickHouse
    echo "--- ClickHouse backup ---"
    CH_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
    CH_BACKUP_FILE="backup-clickhouse-$(date +%Y%m%d-%H%M%S)"
    # Forzar flush de datos en memoria a disco antes del backup
    kubectl exec -n "${NAMESPACE}" "${CH_POD}" -- \
      clickhouse-client --query "SYSTEM FLUSH LOGS"
    # Backup de la base de datos openpanel usando el mecanismo nativo de ClickHouse
    kubectl exec -n "${NAMESPACE}" "${CH_POD}" -- \
      clickhouse-client --query \
      "BACKUP DATABASE openpanel TO File('${CH_BACKUP_FILE}.zip')"
    echo "ClickHouse backup saved: ${CH_BACKUP_FILE}.zip"

    echo "=== Database backups complete ==="
    ;;

  restore)
    RESTORE_BACKUP="${2:-}"
    if [ -z "${RESTORE_BACKUP}" ]; then
      echo "Usage: $0 restore <backup-name>"
      echo ""
      echo "Available backups:"
      velero backup get
      exit 1
    fi
    echo "=== Restoring from backup: ${RESTORE_BACKUP} ==="
    velero restore create --from-backup "${RESTORE_BACKUP}" --wait
    echo "Restore complete."
    ;;

  list)
    echo "=== Available backups ==="
    velero backup get
    ;;

  help|*)
    echo "Usage: $0 <action> [namespace|backup-name]"
    echo ""
    echo "Actions:"
    echo "  backup [namespace]       Create a full Velero backup (default: openpanel)"
    echo "  backup-db                Backup PostgreSQL, Redis y ClickHouse"
    echo "  restore <backup-name>    Restore from a Velero backup"
    echo "  list                     List available backups"
    echo "  help                     Show this help"
    ;;

esac
