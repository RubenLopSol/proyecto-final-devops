# Lista de Capturas de Pantalla

Guarda todas las imágenes en esta carpeta (`docs/screenshots/`) con exactamente los nombres indicados.

---

## ArgoCD — GITOPS.md

| Archivo | Qué capturar |
|---|---|
| `argocd-apps-overview.png` | UI de ArgoCD → pantalla principal con las 3 apps en **Synced + Healthy** |
| `argocd-openpanel-resources.png` | Dentro de la app `openpanel` → pestaña **Resources** mostrando todos los recursos verdes |

**URL:** `http://argocd.local`

---

## CI/CD — CICD.md

| Archivo | Qué capturar |
|---|---|
| `github-actions-ci-success.png` | GitHub Actions → última ejecución del **CI Pipeline** con todos los jobs en verde (✓) |
| `github-actions-cd-success.png` | GitHub Actions → última ejecución del **CD Pipeline** completada con éxito |

**URL:** `https://github.com/RubenLopSol/proyecto-final-devops/actions`

---

## Observabilidad — OBSERVABILITY.md

| Archivo | Qué capturar |
|---|---|
| `grafana-dashboard.png` | Grafana → dashboard principal con todos los paneles visibles (métricas de CPU, memoria, requests) |
| `prometheus-targets.png` | Prometheus → página **Targets** (`/targets`) mostrando todos los endpoints en estado UP |
| `grafana-alert-rules.png` | Grafana → sección **Alerting → Alert rules** mostrando las reglas configuradas |

**URL Grafana:** `http://grafana.local`
**URL Prometheus:** `http://prometheus.local`

---

## Backup — BACKUP-RECOVERY.md

| Archivo | Qué capturar |
|---|---|
| `velero-backups-completed.png` | Terminal con `velero backup get --namespace velero` mostrando backups en estado **Completed** |

---

## Blue-Green — BLUE-GREEN.md

| Archivo | Qué capturar |
|---|---|
| `argocd-blue-deployment.png` | ArgoCD → app `openpanel` → Resources → deployment `openpanel-api-blue` en **Healthy** |
| `blue-green-service.png` | ArgoCD o terminal mostrando el Service `openpanel-api` con selector apuntando a `slot: blue` |

---

## Seguridad — SECURITY.md

| Archivo | Qué capturar |
|---|---|
| `sealed-secrets-argocd.png` | ArgoCD → app `openpanel` → Resources → los SealedSecrets desplegados |
| `sealed-secrets-decrypted.png` | Terminal con `kubectl get secrets -n openpanel` mostrando que los secrets existen (descifrados por el controlador) |

---

## Terraform — TERRAFORM.md

| Archivo | Qué capturar |
|---|---|
| `terraform-apply-localstack.png` | Terminal mostrando el output de `terraform apply` en `terraform/localstack/` con **7 resources created** |
| `terraform-outputs.png` | Terminal con `terraform output` mostrando bucket_name, velero_access_key_id, etc. |

---

## Aplicación funcionando — README / ARCHITECTURE.md

| Archivo | Qué capturar |
|---|---|
| `openpanel-app-running.png` | Navegador en `http://openpanel.local` mostrando la interfaz de OpenPanel |
| `cluster-all-pods-running.png` | Terminal con `kubectl get pods -A` mostrando todos los pods en **Running** |

---

## Resumen — Total: 16 capturas

```
docs/screenshots/
├── argocd-apps-overview.png
├── argocd-openpanel-resources.png
├── github-actions-ci-success.png
├── github-actions-cd-success.png
├── grafana-dashboard.png
├── prometheus-targets.png
├── grafana-alert-rules.png
├── velero-backups-completed.png
├── argocd-blue-deployment.png
├── blue-green-service.png
├── sealed-secrets-argocd.png
├── sealed-secrets-decrypted.png
├── terraform-apply-localstack.png
├── terraform-outputs.png
├── openpanel-app-running.png
└── cluster-all-pods-running.png
```
