# Seguridad — Secrets, Network Policies, RBAC y Hardening

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Visión General

La seguridad se aplica en múltiples capas:

| Capa | Mecanismo | Herramienta |
|---|---|---|
| Secrets en Git | Cifrado con clave del clúster | Sealed Secrets |
| Clave privada del controller | Backup fuera del clúster | AWS Secrets Manager |
| Secrets en pipeline CI | Variables cifradas del repositorio | GitHub Secrets |
| Tráfico de red | Reglas de allow/deny por pod | Network Policies |
| Permisos de pods | No-root, read-only filesystem | SecurityContext |
| Permisos de ArgoCD | Mínimos por componente | RBAC + ServiceAccount |
| Imágenes de contenedor | Escaneo de vulnerabilidades | Trivy (en CI) |

---

## Sealed Secrets — Secrets en Git

En GitOps, todo debe estar en Git — incluyendo los secrets. **Sealed Secrets** permite commitear secrets cifrados de forma segura.

### Cómo funciona — Flujo de datos completo

```
┌─────────────────────────────────────────────────────────────────────────┐
│  CREACIÓN (una vez por secret)                                          │
│                                                                         │
│  Developer                                                              │
│     │                                                                   │
│     │  kubectl create secret --dry-run -o yaml                         │
│     ▼                                                                   │
│  Secret YAML (plaintext) — solo en memoria/pipe, nunca en disco        │
│     │                                                                   │
│     │  kubeseal --cert <public-key>                                     │
│     ▼                                                                   │
│  SealedSecret YAML (cifrado RSA-OAEP) ──► git commit ──► GitHub        │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  DESPLIEGUE (automático vía ArgoCD)                                     │
│                                                                         │
│  GitHub                                                                 │
│     │                                                                   │
│     │  ArgoCD detecta cambio en overlays/staging/sealed-secrets/        │
│     ▼                                                                   │
│  kubectl apply SealedSecret ──► Kubernetes API                         │
│                                      │                                  │
│                                      │  Sealed Secrets Controller       │
│                                      │  (watch SealedSecret resources)  │
│                                      ▼                                  │
│                              Descifra con clave privada RSA             │
│                                      │                                  │
│                                      ▼                                  │
│                              Crea Secret nativo de Kubernetes           │
│                                      │                                  │
│                                      ▼                                  │
│                              Pod lee el Secret como envFrom/volumeMount │
└─────────────────────────────────────────────────────────────────────────┘
```

**Por qué es seguro commitear los SealedSecrets:**

El cifrado usa **RSA-OAEP** con la clave pública del clúster. El resultado es un blob cifrado que solo puede descifrar el controller que tiene la clave privada correspondiente. Sin acceso al clúster, el blob es inútil.

### La clave privada — dónde vive y cómo se protege

Cuando se instala el controller por primera vez (`make sealed-secrets`), genera automáticamente un par de claves RSA-4096 y las almacena como un Kubernetes Secret en el namespace `sealed-secrets`:

```bash
# Ver la clave generada
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key
# NAME                        TYPE                DATA
# sealed-secrets-key-xxxxx    kubernetes.io/tls   2   ← tls.crt (pública) + tls.key (privada)
```

**Riesgo:** si el clúster se destruye, la clave se pierde y los SealedSecrets existentes ya no pueden descifrar. Por eso la clave se respalda en AWS Secrets Manager.

### Backup de la clave en AWS Secrets Manager

La configuración del controller está en `k8s/infrastructure/base/sealed-secrets/values.yaml` — recursos, nodeSelector, securityContext y métricas. El Makefile lo pasa con `--values` al instalar.

Terraform provisiona el slot en Secrets Manager (`terraform/modules/backup-storage/main.tf`, llamado desde cada entorno):

```hcl
resource "aws_secretsmanager_secret" "sealed_secrets_key" {
  name = "devops-cluster/sealed-secrets-master-key"
}
```

Después de instalar el controller, hacer backup de la clave:

```bash
# Exporta la clave del cluster y la almacena en Secrets Manager (LocalStack)
make backup-sealing-key

# Para AWS real (sin LocalStack), pasar el endpoint vacío:
make backup-sealing-key LOCALSTACK_ENDPOINT=""
```

### Recuperar en un nuevo clúster

```bash
# 1. Instalar el controller via kustomize (mismo método que el setup normal)
make sealed-secrets ENV=staging

# 2. Si tienes backup de la clave RSA, restaurarla antes de que ArgoCD sincronice
make restore-sealing-key
# El controller descifra los SealedSecrets existentes en el repo sin necesidad de reseal

# Si NO tienes backup de la clave, regenerar los secrets con la nueva clave del clúster:
make reseal-secrets ENV=staging
git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
git commit -m "chore: reseal secrets for new cluster"
git push
```

### Secrets gestionados

Todos los secrets se almacenan en **un único archivo por entorno**, generado por `make reseal-secrets`:

```
k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
k8s/infrastructure/overlays/prod/sealed-secrets/secrets.yaml
```

| Sección | Secret | Namespace destino | Contenido |
|---|---|---|---|
| § 1 | `postgres-credentials` | `openpanel` | Usuario y contraseña de PostgreSQL |
| § 2 | `redis-credentials` | `openpanel` | Contraseña de Redis |
| § 3 | `clickhouse-credentials` | `openpanel` | Usuario y contraseña de ClickHouse |
| § 4 | `openpanel-secrets` | `openpanel` | DATABASE_URL, CLICKHOUSE_URL, REDIS_URL, API_SECRET |
| § 5 | `grafana-admin-credentials` | `observability` | Usuario y contraseña de Grafana |
| § 6 | `minio-credentials` | `backup` | MINIO_ROOT_USER, MINIO_ROOT_PASSWORD |

El controller vive en el namespace `sealed-secrets` pero crea los Secrets en el namespace declarado en cada SealedSecret (openpanel, observability, backup). Los pods solo pueden leer Secrets de su propio namespace — por eso cada secret apunta al namespace donde el pod espera encontrarlo.

![Sealed Secrets — SealedSecrets gestionados por ArgoCD](../screenshots/sealed-secrets-argocd.png)

### Rotar o actualizar secrets

Todos los secrets se regeneran a la vez con un solo comando:

```bash
# Rotar una o varias credenciales (el resto toma los valores del .secrets o los defaults)
make reseal-secrets ENV=staging POSTGRES_PASSWORD=nueva-pass

# Commitear el nuevo secrets.yaml (los valores son blobs RSA-cifrados, es seguro)
git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml
git commit -m "chore: rotate postgres credentials"
git push
# ArgoCD (app sealed-secrets) aplica el cambio automáticamente
```

### Verificar que el Secret se descifra

```bash
# El controlador crea el Secret automáticamente
kubectl get secret nuevo-secret -n openpanel

# Ver el valor descifrado (solo si tienes permisos en el clúster)
kubectl get secret nuevo-secret -n openpanel \
  -o jsonpath='{.data.clave}' | base64 -d
```

![Sealed Secrets — Secrets descifrados automáticamente en el namespace openpanel](../screenshots/sealed-secrets-decrypted.png)

---

## Network Policies — Segmentación de Red

Se aplica un modelo **deny-by-default**: todo el tráfico está bloqueado por defecto, y solo se permiten las conexiones explícitamente necesarias.

### Políticas aplicadas en el namespace `openpanel`

| Policy | Tipo | Descripción |
|---|---|---|
| `default-deny-all` | Ingress + Egress | Bloquea todo el tráfico por defecto |
| `allow-dns` | Egress | Permite resolución DNS (UDP/TCP 53) para todos los pods |
| `allow-api-ingress` | Ingress | API acepta tráfico solo del Ingress Controller y del Dashboard |
| `allow-api-egress` | Egress | API puede conectar a PostgreSQL (5432), ClickHouse (8123/9000), Redis (6379) |
| `allow-worker-egress` | Egress | Worker puede conectar a PostgreSQL, ClickHouse y Redis |
| `allow-start-ingress` | Ingress | Dashboard acepta tráfico solo del Ingress Controller |
| `allow-start-egress` | Egress | Dashboard puede conectar solo a la API (3000) |
| `allow-db-ingress` | Ingress | Bases de datos aceptan conexiones solo de API y Worker |
| `allow-prometheus-scraping` | Ingress | Exporters (9121, 9187, 9363) aceptan scraping desde namespace `observability` |

### Diagrama de conectividad permitida

![Allow connect](../diagrams/img/allow_connect.png)


---

## SecurityContext — Contenedores Non-Root

Todos los pods están configurados para ejecutarse como usuario no-root:

```yaml
# Ejemplo en el deployment de la API
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    fsGroup: 1001
  containers:
    - name: api
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
```

El mismo patrón se aplica en Grafana (usuario 472), Prometheus y los demás componentes del stack de observabilidad.

---

## RBAC — Permisos Mínimos

Cada componente tiene su propio **ServiceAccount** con solo los permisos necesarios.

### Prometheus

Prometheus necesita permisos de lectura sobre los recursos del clúster para el autodescubrimiento de targets (nodos, pods, servicios, endpoints e ingresses).

El RBAC de Prometheus (ClusterRole + ClusterRoleBinding + ServiceAccount) es gestionado automáticamente por el chart **`kube-prometheus-stack`** al desplegarse vía ArgoCD. No es necesario mantener YAMLs manuales de RBAC.

```yaml
# Permisos que aplica el chart internamente:
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
```

### Promtail

Promtail necesita permisos para listar pods y leer sus logs. Al igual que Prometheus, el RBAC es gestionado automáticamente por el chart **`grafana/promtail`**:

```yaml
# Permisos que aplica el chart internamente:
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
```

### ArgoCD

ArgoCD tiene su propio sistema de RBAC. El AppProject `openpanel` limita las aplicaciones a los namespaces `openpanel`, `observability`, `backup`, `sealed-secrets` y `kube-system`. El controller de Sealed Secrets necesita permisos en `sealed-secrets` para gestionar la clave RSA y en el resto de namespaces para crear los Secrets descifrados.

---

## Escaneo de Imágenes con Trivy

**Trivy** se ejecuta en el pipeline CI después de cada build de imagen.

```yaml
# .github/workflows/ci-build-publish.yml — job security-scan
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@0.28.0
  with:
    image-ref: "ghcr.io/<owner>/openpanel-api:latest"
    format: "sarif"
    severity: "CRITICAL,HIGH"
    exit-code: "1"         # Bloquea el pipeline si hay vulnerabilidades con parche disponible
    ignore-unfixed: true   # Ignora vulnerabilidades sin parche publicado (no corregibles localmente)
```

Los resultados se suben automáticamente a la pestaña **Security** del repositorio GitHub (formato SARIF) con `if: always()` — el SARIF se sube incluso si Trivy falla.

---

## GitHub Secrets — Secrets del Pipeline CI

Los tokens necesarios en el pipeline se gestionan como GitHub Secrets (cifrados en GitHub):

| Secret | Uso |
|---|---|
| `GITHUB_TOKEN` | Login en GHCR para push de imágenes (automático, no requiere configuración) |

No hay secrets adicionales que configurar manualmente — GitHub proporciona `GITHUB_TOKEN` automáticamente en cada workflow run.

---

## Verificar el Estado de Seguridad

```bash
# Verificar que ningún pod corre como root
kubectl get pods -n openpanel -o jsonpath=\
  '{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext.runAsUser}{"\n"}{end}'

# Verificar Network Policies activas
kubectl get networkpolicies -n openpanel

# Verificar Sealed Secrets descifrados
kubectl get secrets -n openpanel

# Ver eventos del Sealed Secrets controller
kubectl logs -n sealed-secrets \
  deployment/sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```
