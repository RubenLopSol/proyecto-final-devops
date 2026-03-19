# Guia paso a paso — Proyecto DevOps OpenPanel

Guia secuencial para completar el proyecto desde cero. Cada fase depende de la anterior. No avances a la siguiente fase hasta que la actual funcione correctamente.

---

## Estado actual de tu maquina (actualizado)

**Herramientas ya instaladas — no necesitas reinstalarlas:**
| Herramienta | Version | Estado |
|---|---|---|
| Docker | 29.2.1 | ✅ Listo |
| kubectl | v1.33.2 (con kustomize v5.6.0 integrado) | ✅ Listo |
| Minikube | v1.37.0 | ✅ Listo |
| Helm | v3.16.3 | ✅ Listo (extra, util) |
| Terraform | v1.5.5 | ✅ Listo (no se usa en el proyecto) |

> **Nota sobre kustomize:** No necesitas instalar `kustomize` como binario separado.
> Usa `kubectl kustomize <dir>` o `kubectl apply -k <dir>` directamente. Es equivalente.

**Herramientas adicionales instaladas (Fase 0):**
| Herramienta | Version | Estado |
|---|---|---|
| ArgoCD CLI | latest | ✅ Instalado |
| kubeseal | v0.24.5 | ✅ Instalado |
| Velero CLI | v1.13.0 | ✅ Instalado |
| GitHub CLI (gh) | latest | ✅ Instalado |

**Estructura del proyecto — ya creada, no toques nada:**
- Manifiestos de Kubernetes completos en `k8s/` (app, observabilidad, backup, ArgoCD)
- Workflows de CI/CD en `.github/workflows/ci.yml` y `cd.yml`
- Scripts de automatizacion en `scripts/` (setup-minikube, install-argocd, blue-green-switch, backup-restore)
- Documentacion base en `docs/` con diagramas en `docs/diagrams/`
- `.gitignore` configurado

**Lo que te toca hacer a ti, en orden:**
1. Instalar las 4 herramientas que faltan (Fase 0) ← **EMPEZAMOS AQUI**
2. Crear el repo en GitHub y reemplazar `GITHUB_USER` por tu usuario real (Fase 1)
3. Construir las imagenes Docker de OpenPanel y subirlas a GHCR (Fase 2)
4. Levantar Minikube y desplegar bases de datos + aplicacion (Fases 3-5)
5. Hacer push para que el CI corra y verificar que pasa verde (Fase 6)
6. Instalar ArgoCD y conectarlo con tu repo (Fase 7)
7. Crear los Sealed Secrets con kubeseal y commitearlos (Fase 8)
8. Verificar que Prometheus, Grafana, Loki y Tempo funcionan, crear dashboards (Fases 9-11)
9. Probar el Blue-Green switch y el rollback (Fase 12)
10. Configurar Velero con MinIO, hacer backup y probar restore (Fase 13)
11. Escribir la documentacion final (Fase 14)
12. Pasar el checklist completo y entregar (Fase 15)

---

## Estrategia de commits Git

El historial de commits debe contar la historia del proyecto de forma logica.
La carpeta `docs/` se sube **al final**, en la Fase 14, para que el registro sea real.

### Historial de commits esperado (de mas antiguo a mas reciente)

```
* docs: complete project documentation                          ← Fase 14
* chore: update image tags to main-<SHA>                       ← CD automatico (varias veces)
* feat: add velero backup schedules                             ← Fase 13 (si hay cambios)
* test: verify blue-green switch documented                     ← Fase 12 (opcional)
* feat: add OpenTelemetry env vars for tracing                  ← Fase 11 (si instrumentas)
* feat: add sealed secrets (encrypted, safe to commit)          ← Fase 8
* fix: scale start deployment to 2 replicas                    ← Fase 7 (test auto-sync)
* ci: trigger first pipeline run                               ← Fase 6
* fix: adjust Dockerfiles for non-root user                    ← Fase 2 (solo si hace falta)
* feat: add k8s manifests, CI/CD workflows and scripts         ← Fase 1
* Initial commit: project structure                            ← Fase 1
```

### Reglas de commits para este proyecto

- **NO** incluyas `docs/` en los commits de infraestructura. Va solo al final.
- **NO** commitees nunca: `.env`, `credentials-velero`, `*.sql.gz`, secrets en texto plano.
- Los commits del CD workflow (`chore: update image tags...`) los hace GitHub Actions automaticamente. No los hagas a mano.
- Usa prefijos convencionales: `feat:`, `fix:`, `ci:`, `chore:`, `docs:`, `test:`
- Cada commit debe poder compilarse/desplegarse por si solo (no rompas el estado intermedio).

---

## Indice

- [Fase 0: Preparacion del entorno](#fase-0-preparacion-del-entorno)
- [Fase 1: Repositorio y GitHub](#fase-1-repositorio-y-github)
- [Fase 2: Containerizacion de OpenPanel](#fase-2-containerizacion-de-openpanel)
- [Fase 3: Cluster Minikube](#fase-3-cluster-minikube)
- [Fase 4: Despliegue de bases de datos](#fase-4-despliegue-de-bases-de-datos)
- [Fase 5: Despliegue de la aplicacion](#fase-5-despliegue-de-la-aplicacion)
- [Fase 6: CI con GitHub Actions](#fase-6-ci-con-github-actions)
- [Fase 7: ArgoCD y GitOps](#fase-7-argocd-y-gitops)
- [Fase 8: Sealed Secrets](#fase-8-sealed-secrets)
- [Fase 9: Observabilidad — Prometheus y Grafana](#fase-9-observabilidad--prometheus-y-grafana)
- [Fase 10: Observabilidad — Loki y Promtail](#fase-10-observabilidad--loki-y-promtail)
- [Fase 11: Observabilidad — Tempo](#fase-11-observabilidad--tempo)
- [Fase 12: Blue-Green Deployment](#fase-12-blue-green-deployment)
- [Fase 13: Backup con Velero y MinIO](#fase-13-backup-con-velero-y-minio)
- [Fase 14: Documentacion final](#fase-14-documentacion-final)
- [Fase 15: Validacion y entrega](#fase-15-validacion-y-entrega)

---

## Fase 0: Preparacion del entorno

> Docker, kubectl (con kustomize integrado) y Minikube ya estan instalados en tu maquina.
> Solo necesitas instalar las 4 herramientas que faltan.

### 0.1 Instalar ArgoCD CLI

```bash
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /tmp/argocd
sudo mv /tmp/argocd /usr/local/bin/argocd
```

### 0.2 Instalar kubeseal (v0.24.5)

```bash
curl -OL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/kubeseal-0.24.5-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.5-linux-amd64.tar.gz kubeseal
sudo mv kubeseal /usr/local/bin/
rm kubeseal-0.24.5-linux-amd64.tar.gz
```

### 0.3 Instalar Velero CLI (v1.13.0)

```bash
curl -LO https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz
tar -xvzf velero-v1.13.0-linux-amd64.tar.gz
sudo mv velero-v1.13.0-linux-amd64/velero /usr/local/bin/
rm -rf velero-v1.13.0-linux-amd64*
```

### 0.4 Instalar GitHub CLI (gh)

```bash
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y
```

### 0.5 Verificar todas las instalaciones

```bash
docker --version
kubectl version --client
minikube version
argocd version --client
kubeseal --version
velero version --client-only
gh --version
```

**Checkpoint:** Los 7 comandos devuelven version sin error. Las 4 nuevas herramientas instaladas correctamente.

---

## Fase 1: Repositorio y GitHub

> El repositorio Git local NO esta inicializado todavia. La estructura de archivos ya existe pero no hay `.git/`.

### 1.1 Inicializar el repositorio Git local

```bash
cd ~/Desktop/Master/proyecto_final
git init
git add .gitignore README.md
git commit -m "Initial commit: project structure"
```

> Solo .gitignore y README.md en el primer commit. El resto va en el siguiente commit (paso 1.7).

### 1.2 Autenticarte en GitHub con gh

```bash
gh auth login
# Selecciona: GitHub.com > HTTPS > Login with a web browser
# Sigue las instrucciones (se abre el navegador)
```

### 1.3 Crear el repositorio en GitHub y subir todo

```bash
gh repo create proyecto-final-devops --private --source=. --push
```

> Esto crea el repo como privado en tu cuenta, lo enlaza como remote `origin` y hace push del commit inicial.

### 1.4 Reemplazar GITHUB_USER en todos los manifiestos

El placeholder `GITHUB_USER` aparece en los manifiestos de ArgoCD y en el workflow de CI/CD.
Sustituye por tu usuario real de GitHub:

```bash
# Reemplaza TU_USUARIO por tu nombre exacto de GitHub (case-sensitive)
export GITHUB_USER="TU_USUARIO"

grep -rl "GITHUB_USER" k8s/ .github/ | xargs sed -i "s/GITHUB_USER/${GITHUB_USER}/g"

# Verificar que no queda ningun placeholder
grep -r "GITHUB_USER" k8s/ .github/
# Si no devuelve nada, esta correcto
```

Archivos afectados:
- `k8s/argocd/applications/openpanel-app.yaml`
- `k8s/argocd/applications/observability-app.yaml`
- `k8s/argocd/applications/backup-app.yaml`
- `.github/workflows/ci.yml`
- `.github/workflows/cd.yml`

### 1.5 Configurar permisos de GitHub Actions para escribir al repositorio

Ve a tu repo en GitHub > **Settings** > **Actions** > **General** > **Workflow permissions**:
- Selecciona: **Read and write permissions**
- Guarda

> Esto es necesario para que el workflow CD pueda hacer commit de los nuevos tags de imagen.

### 1.6 Anadir credentials-velero al .gitignore

El archivo de credenciales de Velero que crearemos en la Fase 13 NO debe ir a Git.
Anadelo ahora para no olvidarlo:

```bash
echo "credentials-velero" >> .gitignore
```

### 1.7 Commit con toda la estructura (SIN docs/) y push

> `docs/` NO va en este commit. Se subira al final, en la Fase 14, para que el historial
> refleje que la documentacion se escribio despues de implementar todo.

```bash
git add k8s/ .github/ scripts/ .gitignore
git commit -m "feat: add k8s manifests, CI/CD workflows and scripts"
git push
```

> Despues de este push, GitHub Actions intentara correr el CI. Es normal que falle
> porque las imagenes Docker aun no existen en GHCR. Lo arreglamos en la Fase 2 y 6.

### 1.8 Habilitar GitHub Container Registry (GHCR)

Desde tu maquina, loguea Docker contra GHCR usando un Personal Access Token (PAT):

1. Ve a GitHub > tu perfil > **Settings** > **Developer settings** > **Personal access tokens** > **Tokens (classic)**
2. Crea un token con permisos: `write:packages`, `read:packages`, `delete:packages`
3. Guarda el token (solo se ve una vez)

```bash
# Exporta el token para usarlo
export GHCR_TOKEN="ghp_TU_TOKEN_AQUI"

# Login a GHCR
echo $GHCR_TOKEN | docker login ghcr.io -u TU_USUARIO --password-stdin
# Debe devolver: Login Succeeded
```

> Este mismo token lo necesitaras en la Fase 2 para hacer push de imagenes.
> No es necesario crearlo como GitHub Secret para el CI: el workflow usa `GITHUB_TOKEN` automatico.

**Checkpoint:** Repositorio `proyecto-final-devops` visible en tu GitHub con toda la estructura. Sin placeholders `GITHUB_USER` en ningun archivo.

---

## Fase 2: Containerizacion de OpenPanel

OpenPanel es un monorepo con `pnpm`. Tiene 3 Dockerfiles:
- `openpanel/apps/api/Dockerfile` — API Fastify (puerto 3333)
- `openpanel/apps/start/Dockerfile` — Dashboard Next.js (puerto 3000)
- `openpanel/apps/worker/Dockerfile` — Worker BullMQ

El contexto de build para los 3 es la raiz del monorepo (`openpanel/`), no la carpeta de cada app.

### 2.0 (Importante) Verificar que openpanel NO es un submódulo git

Si el directorio `openpanel/` tiene su propio `.git` interno (es un submódulo), hay que convertirlo a directorio normal antes de poder commitear cambios en él:

```bash
cd ~/Desktop/Master/proyecto_final

# Verificar si es submodulo
git submodule status

# Si aparece openpanel en la lista, convertirlo:
git rm --cached openpanel
rm -rf openpanel/.git
git add openpanel/
git commit -m "chore: convert openpanel submodule to regular directory"
git push
```

Si no aparece nada en `git submodule status`, este paso no es necesario.

### 2.1 Construir las 3 imagenes

```bash
cd ~/Desktop/Master/proyecto_final/openpanel

# API (Fastify - event tracking)
docker build -f apps/api/Dockerfile -t openpanel-api:test .

# Dashboard (Next.js)
docker build -f apps/start/Dockerfile -t openpanel-start:test .

# Worker (BullMQ background jobs)
docker build -f apps/worker/Dockerfile -t openpanel-worker:test .
```

> El build puede tardar varios minutos la primera vez (monorepo grande con muchas dependencias).
> Si algun build falla, NO modifiques codigo de negocio. Ajusta solo el Dockerfile
> (dependencias, paths, build args). Documenta cada cambio que hagas en `docs/`.

### 2.2 Verificar que las imagenes arrancan

```bash
# Probar que la API arranca (saldra error de DB por falta de conexion, es NORMAL)
docker run --rm -p 3333:3333 openpanel-api:test
# Ctrl+C para parar

# Verificar que el usuario NO es root (requisito de seguridad del proyecto)
docker run --rm openpanel-api:test whoami
# Debe devolver un usuario no-root (ej: node, appuser...). Si devuelve "root", ajusta el Dockerfile.

docker run --rm openpanel-start:test whoami
docker run --rm openpanel-worker:test whoami
```

> Si algun contenedor devuelve "root", el CI fallara en el check de kube-linter.
> La correccion es anadir al Dockerfile: `USER node` (o el usuario que corresponda)
> antes del CMD/ENTRYPOINT.

> **Si modificas algun Dockerfile**, haz commit de los cambios:
> ```bash
> git add openpanel/apps/api/Dockerfile      # o el que hayas modificado
> git commit -m "fix: adjust Dockerfile for non-root user"
> git push
> ```
> Si los Dockerfiles ya funcionan sin cambios, no hay commit en esta fase.

### 2.3 Push manual a GHCR (primera vez)

Asegurate de tener la variable `GITHUB_USER` exportada y el login de Docker hecho (Fase 1.8):

```bash
export GITHUB_USER="TU_USUARIO"

# Etiquetar
docker tag openpanel-api:test ghcr.io/${GITHUB_USER}/openpanel-api:latest
docker tag openpanel-start:test ghcr.io/${GITHUB_USER}/openpanel-start:latest
docker tag openpanel-worker:test ghcr.io/${GITHUB_USER}/openpanel-worker:latest

# Subir a GHCR
docker push ghcr.io/${GITHUB_USER}/openpanel-api:latest
docker push ghcr.io/${GITHUB_USER}/openpanel-start:latest
docker push ghcr.io/${GITHUB_USER}/openpanel-worker:latest
```

### 2.4 Hacer las imagenes publicas

En GitHub > tu perfil (icono arriba a la derecha) > **Packages** > selecciona cada imagen > **Package settings** > **Change visibility** > **Public**.

Repite para las 3 imagenes: `openpanel-api`, `openpanel-start`, `openpanel-worker`.

> Si prefieres mantenerlas privadas, necesitaras crear un `imagePullSecret` en Kubernetes.
> Para este proyecto educativo, publicas es mas simple y funciona igual.

**Checkpoint:** Las 3 imagenes visibles en `https://github.com/TU_USUARIO?tab=packages`.
Cada una debe mostrar tag `latest`.

---

## Fase 3: Cluster Minikube

El script `setup-minikube.sh` crea un cluster llamado `openpanel` con:
- Kubernetes v1.28.0
- 6 CPUs, 12 GB RAM, 60 GB disco
- Driver: Docker
- Addons: ingress, metrics-server, dashboard, storage-provisioner
- Crea automaticamente los 4 namespaces del proyecto

> Asegurate de tener al menos 6 CPUs y 12 GB de RAM libres antes de continuar.
> Comprueba con: `nproc` y `free -h`
>
> Si tienes menos de 12 GB disponibles, edita `scripts/setup-minikube.sh` y cambia `MEMORY="12288"` a `MEMORY="8192"` antes de ejecutar el script. Luego commitea el cambio:
> ```bash
> git add scripts/setup-minikube.sh
> git commit -m "chore: reduce minikube memory to 8192 for local machine"
> git push
> ```

### 3.1 Levantar el cluster

```bash
cd ~/Desktop/Master/proyecto_final
./scripts/setup-minikube.sh
```

El script tardara unos minutos. Al final mostrara los pasos siguientes.

### 3.2 Verificar el cluster

```bash
kubectl get nodes
# STATUS debe ser Ready

kubectl get namespaces
# Deben existir al menos: openpanel, observability, argocd, backup, default, kube-system

minikube status -p openpanel
# host, kubelet, apiserver: Running
# kubeconfig: Configured
```

### 3.3 Verificar addons

```bash
minikube addons list -p openpanel | grep -E "ingress|metrics-server|dashboard|storage"
# Los 4 deben aparecer como "enabled"
```

### 3.4 Configurar DNS local

```bash
echo "$(minikube ip -p openpanel) openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local" | sudo tee -a /etc/hosts

# Verificar (debe aparecer UNA sola linea con todos los dominios)
grep "openpanel.local" /etc/hosts
```

> **Importante:** Ejecuta este comando en UNA SOLA LINEA para evitar que se rompa en dos entradas malformadas en `/etc/hosts`. Si ya tienes entradas duplicadas o rotas, edita el archivo manualmente: `sudo nano /etc/hosts`

### 3.5 Verificar Ingress Controller

```bash
kubectl get pods -n ingress-nginx
# El pod del controller debe estar Running (puede tardar 1-2 minutos)

# Test rapido (espera a que el pod este Running antes)
curl -I http://openpanel.local 2>/dev/null | head -1
# Devolvera HTTP/1.1 404 (normal, aun no hay nada desplegado detras del ingress)
```

**Checkpoint:** `kubectl get ns` muestra los 4 namespaces. `minikube status -p openpanel` todo Running. `curl http://openpanel.local` devuelve 404.

---

## Fase 4: Despliegue de bases de datos

### 4.1 Crear secrets de bases de datos (temporales, luego seran Sealed Secrets)

> **IMPORTANTE:** Crea los secrets ANTES de desplegar los pods. Si despliegas primero, los pods quedarán en `CreateContainerConfigError` hasta que existan los secrets.

```bash
# PostgreSQL
kubectl create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=openpanel \
  --from-literal=POSTGRES_PASSWORD=openpanel123 \
  -n openpanel

# ClickHouse
kubectl create secret generic clickhouse-credentials \
  --from-literal=CLICKHOUSE_USER=openpanel \
  --from-literal=CLICKHOUSE_PASSWORD=openpanel123 \
  -n openpanel

# Redis
kubectl create secret generic redis-credentials \
  --from-literal=REDIS_PASSWORD=openpanel123 \
  -n openpanel
```

### 4.2 Desplegar bases de datos una a una

Despliega por separado para aislar errores:

```bash
# PostgreSQL
kubectl apply -f k8s/base/openpanel/postgres-statefulset.yaml
kubectl apply -f k8s/base/openpanel/postgres-service.yaml

# Esperar a que este Ready
kubectl wait --for=condition=ready pod -l app=postgres -n openpanel --timeout=120s

# Verificar
kubectl exec -n openpanel postgres-0 -- pg_isready -U openpanel
# Debe devolver "accepting connections"
```

```bash
# ClickHouse
kubectl apply -f k8s/base/openpanel/clickhouse-statefulset.yaml
kubectl apply -f k8s/base/openpanel/clickhouse-service.yaml

kubectl wait --for=condition=ready pod -l app=clickhouse -n openpanel --timeout=120s

# Verificar
kubectl exec -n openpanel clickhouse-0 -- clickhouse-client --query "SELECT 1"
# Debe devolver "1"
```

```bash
# Redis
kubectl apply -f k8s/base/openpanel/redis-deployment.yaml
kubectl apply -f k8s/base/openpanel/redis-service.yaml

kubectl wait --for=condition=ready pod -l app=redis -n openpanel --timeout=120s

# Verificar
kubectl exec -n openpanel $(kubectl get pod -l app=redis -n openpanel -o jsonpath='{.items[0].metadata.name}') -- redis-cli ping
# Debe devolver "PONG"
```

### 4.3 Verificar PVCs

```bash
kubectl get pvc -n openpanel
# Todas deben estar en status "Bound"
```

**Checkpoint:** 3 pods de bases de datos Running, 3 PVCs Bound, conexiones verificadas.

---

## Fase 5: Despliegue de la aplicacion

### 5.1 Crear secrets de aplicacion

> **IMPORTANTE — Redis URL:** Usa `redis://default:openpanel123@redis:6379` (con usuario `default`).
> El formato `redis://:password@...` (sin usuario) hace que ioredis envie `AUTH "" password`
> que Redis 7 rechaza como WRONGPASS. El usuario `default` es el usuario ACL estandar de Redis 7.

> **IMPORTANTE — ClickHouse URL:** Usa `http://default:openpanel123@clickhouse:8123/openpanel`
> (usuario `default`, no `openpanel`). ClickHouse no tiene usuario `openpanel` por defecto.

```bash
kubectl create secret generic openpanel-secrets \
  --from-literal=DATABASE_URL="postgresql://openpanel:openpanel123@postgres:5432/openpanel" \
  --from-literal=CLICKHOUSE_URL="http://default:openpanel123@clickhouse:8123/openpanel" \
  --from-literal=REDIS_URL="redis://default:openpanel123@redis:6379" \
  --from-literal=API_SECRET="super-secret-api-key-change-in-production" \
  -n openpanel
```

### 5.2 Ejecutar migraciones de base de datos

> **IMPORTANTE:** Hay que correr las 134 migraciones de Prisma antes de desplegar la app.
> El worker falla con `The table public.salts does not exist` si se salta este paso.
>
> Usa `prisma@6.14.0` explicitamente — la version del proyecto. `npx prisma` (sin version)
> descarga la ultima (v7+) que rechaza `directUrl` en schema.prisma con error de validacion.

```bash
# Aplica despues de desplegar la API (necesita DATABASE_URL del secret)
kubectl exec -n openpanel deploy/openpanel-api-blue -- \
  sh -c "cd /app && DATABASE_URL_DIRECT=\$DATABASE_URL npx prisma@6.14.0 migrate deploy --schema packages/db/prisma/schema.prisma" 2>&1 | tail -5
# Debe terminar con: All migrations have been successfully applied.
```

### 5.2b Aplicar ConfigMap

```bash
kubectl apply -f k8s/base/openpanel/configmap.yaml
```

### 5.3b Desplegar servicios de aplicacion

```bash
# API (solo Blue por ahora)
kubectl apply -f k8s/base/openpanel/api-deployment-blue.yaml
kubectl apply -f k8s/base/openpanel/api-service.yaml

# Dashboard
kubectl apply -f k8s/base/openpanel/start-deployment.yaml
kubectl apply -f k8s/base/openpanel/start-service.yaml

# Worker
kubectl apply -f k8s/base/openpanel/worker-deployment.yaml
```

### 5.4 Verificar pods

```bash
kubectl get pods -n openpanel
# Todos deben estar Running (o al menos sin CrashLoopBackOff)
```

> **Si un pod falla**, diagnostica con:
> ```bash
> kubectl describe pod <nombre-del-pod> -n openpanel
> kubectl logs <nombre-del-pod> -n openpanel
> ```
> Errores comunes:
> - `ImagePullBackOff` — La imagen no existe en GHCR o es privada. Revisa Fase 2.4.
> - `CrashLoopBackOff` — El contenedor arranca y se cae. Revisa logs.
> - `readOnlyRootFilesystem` — Next.js o la API necesitan escribir en `/tmp`. Ajusta el securityContext o monta un emptyDir en `/tmp`.
> - Variables de entorno incorrectas — Revisa el ConfigMap y los Secrets.

### 5.5 Aplicar Ingress

```bash
kubectl apply -f k8s/base/openpanel/ingress.yaml
```

### 5.6 Probar acceso

```bash
# API - liveness (siempre devuelve 200 si el proceso esta vivo)
curl -s http://api.openpanel.local/healthz/live
# Debe devolver: {"live":true}

# Dashboard
curl -s -o /dev/null -w "%{http_code}" http://openpanel.local
# Debe devolver 200 (o 302 si redirige a login)
```

Abre en el navegador: `http://openpanel.local`

> **Nota:** El endpoint correcto de la API es `/healthz/live` (liveness) y `/healthcheck` (readiness).
> NO existe `/health` — devuelve 404.

### 5.7 Aplicar Network Policies

```bash
kubectl apply -f k8s/base/openpanel/network-policies.yaml

# Verificar que la app sigue funcionando
curl -s http://api.openpanel.local/healthz/live
```

> Si la app deja de funcionar despues de aplicar Network Policies, revisa
> las reglas en `network-policies.yaml`. Puede que falte permitir algun flujo.

**Checkpoint:** OpenPanel accesible en el navegador. API responde `{"live":true}` en `/healthz/live`.

---

### Fixes aplicados en Fase 5 (ya incorporados en los manifests del repo)

Estos problemas se encontraron durante la implementacion. Los manifests ya estan corregidos,
pero se documentan aqui para entender que se cambio y por que.

| Problema | Causa | Solucion |
|---|---|---|
| `InvalidImageName` en pods | Imagen con mayusculas `ghcr.io/RubenLopSol/` | GHCR requiere minusculas: `ghcr.io/rubenlopsol/` |
| API en `CrashLoopBackOff` — corepack falla | `readOnlyRootFilesystem: true` + corepack escribe en `/.cache` | Agregar `HOME=/tmp`, `COREPACK_HOME=/tmp/corepack`, `XDG_CACHE_HOME=/tmp/.cache` y emptyDir en `/tmp` |
| API se reinicia cada ~60s — `ELIFECYCLE` | El script `pnpm start` llama a `dotenv -e ../../.env` que falla si no existe el fichero | Override `command: ["node", "dist/index.js"]` en el Deployment para saltar dotenv |
| Liveness probe mata el pod — HTTP 404 | La ruta `/health` no existe; las rutas reales son `/healthz/live` y `/healthcheck` | Corregir `path` en liveness y readiness probes |
| Liveness probe timeout — SIGTERM cada ~60s | Respuestas del endpoint pueden tardar >1s; timeout por defecto es 1s | Subir `timeoutSeconds: 10` y `failureThreshold: 5` |
| Readiness probe siempre 503 | `/healthz/ready` hace `db.project.findFirst()` — devuelve null en DB vacia | Cambiar readiness a `/healthcheck` que usa `SELECT 1` |
| Worker `Connection is closed` Redis | `redis://:password@...` hace `AUTH "" password` rechazado por Redis 7 ACL | Usar `redis://default:password@...` (usuario `default` explicito) |
| Worker falla con `table public.salts does not exist` | Las migraciones de Prisma nunca se ejecutaron contra la DB | Correr `npx prisma@6.14.0 migrate deploy` desde el pod de la API (paso 5.2) |
| `npx prisma migrate deploy` falla con error de validacion `directUrl` | `npx prisma` descarga v7+ que elimino soporte de `directUrl` en schema.prisma | Usar version especifica `npx prisma@6.14.0` (version del proyecto) |

---

## Fase 6: CI con GitHub Actions

El workflow CI esta en `.github/workflows/ci.yml`. Tiene estos jobs:

| Job | Que hace | Cuando corre |
|---|---|---|
| `lint-and-test` | lint, type-check, tests (pnpm, Node 22) | Siempre |
| `validate-infra` | kustomize build, kubeconform, kube-linter, hadolint, kubectl dry-run | Siempre |
| `build-and-push` | Construye y sube las 3 imagenes a GHCR | Solo en push a main, si los 2 anteriores pasan |
| `security-scan` | Trivy (vulnerabilidades) en las 3 imagenes | Despues de build-and-push |
| `secret-scan` | Gitleaks (secretos en codigo) | Siempre |

Los jobs `lint-and-test` y `validate-infra` corren en paralelo.

### 6.1 Disparar el CI con un push

```bash
# Haz un cambio menor en el README (una linea en blanco es suficiente)
echo "" >> README.md
git add README.md
git commit -m "ci: trigger first pipeline run"
git push
```

> Este commit existe solo para verificar que el pipeline funciona end-to-end.
> Si ya hiciste un push en la Fase 2 (Dockerfiles modificados), ese push ya habra disparado el CI.
> En ese caso, usa `gh run list` para ver si ya hay un run y saltate este paso.

### 6.2 Seguir la ejecucion desde terminal

```bash
gh run list --limit 5
# Muestra el ID y estado del workflow en ejecucion

# Ver detalle de la ejecucion (reemplaza <run-id> con el ID del run)
gh run view <run-id>

# Ver logs de un job especifico en tiempo real
gh run watch <run-id>
```

O desde el navegador: GitHub > tu repo > pestaña **Actions**.

### 6.3 Problemas comunes y soluciones

**Si falla `lint-and-test`:**
- `pnpm install` falla → Verifica que `openpanel/pnpm-lock.yaml` existe (es un archivo grande, debe estar en el repo)
- `pnpm lint` falla → OpenPanel usa Biome para lint. Verifica que el script `lint` existe en `openpanel/package.json`
- `pnpm test` falla → Los tests pueden fallar por falta de base de datos. Si el workflow no usa mocks, puede que necesites comentar el step `pnpm test` temporalmente y documentar por que

**Si falla `validate-infra`:**
- `kustomize build` falla → Algun archivo listado en un `kustomization.yaml` no existe. Revisa `k8s/overlays/local/kustomization.yaml` y `k8s/base/*/kustomization.yaml`
- `kubeconform` falla → Un YAML tiene un campo invalido segun el schema de K8s v1.28. El mensaje de error indica el archivo y campo exacto
- `kube-linter` falla → Un manifiesto no tiene resource limits, liveness/readiness probe, o corre como root. Revisa el output: dice exactamente que check falla y en que archivo
- `hadolint` falla → El Dockerfile tiene warnings. El step usa `|| true` por lo que NO bloquea el pipeline

**Si falla `build-and-push`:**
- `Push a GHCR falla` → Verifica que configuraste **Read and write permissions** en Settings > Actions > General (Fase 1.5)
- `Docker build falla` → Igual que Fase 2.1, ajusta el Dockerfile

### 6.4 Verificar imagenes actualizadas en GHCR

```bash
gh api user/packages?package_type=container | jq '.[].name'
# Deben aparecer: openpanel-api, openpanel-start, openpanel-worker
```

**Checkpoint:** Pipeline CI verde en GitHub Actions. Los 5 jobs pasan. Las 3 imagenes en GHCR tienen tag `main-<SHA>`.

---

## Fase 7: ArgoCD y GitOps

### 7.1 Instalar ArgoCD

```bash
./scripts/install-argocd.sh
```

> **PROBLEMA CONOCIDO — CRD demasiado grande:**
> Si aparece el error `metadata.annotations: Too long: must have at most 262144 bytes`, aplica los manifiestos con server-side apply:
> ```bash
> kubectl apply -n argocd --server-side --force-conflicts \
>   -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
> ```

### 7.2 Parchear argocd-server para modo HTTP (sin TLS)

El ingress que crea el script usa ssl-passthrough, que requiere configuracion especial en nginx. Es mas simple correr argocd-server en modo inseguro (HTTP) y acceder por HTTP:

```bash
# Parchar argocd-server para modo --insecure
kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# Actualizar el ingress a HTTP (puerto 80)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

kubectl rollout status deployment/argocd-server -n argocd
```

### 7.3 Acceder a ArgoCD

Accede por **http** (sin s):
```
http://argocd.local
```

Usuario: `admin`
Password: la que mostro el script (campo `YFnb7rOJuFGytG7L` o similar)

> **Si el login falla con "Invalid username or password":**
> El secret inicial puede haber caducado. Resetea la password:
> ```bash
> pip3 install bcrypt 2>/dev/null
> HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'admin123', bcrypt.gensalt(10)).decode())")
> kubectl -n argocd patch secret argocd-secret \
>   -p "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
> kubectl rollout restart deployment argocd-server -n argocd
> # Espera 30s. Login con admin / admin123
> ```

### 7.4 Aplicar el AppProject y las Applications

```bash
kubectl apply -f k8s/argocd/projects/
kubectl apply -f k8s/argocd/applications/
```

### 7.5 Verificar sync en ArgoCD

```bash
kubectl get applications -n argocd
# Las 3 apps deben aparecer. Status puede ser "OutOfSync" inicialmente.
```

En la UI de ArgoCD (`http://argocd.local`) deberias ver las 3 apps: openpanel, observability, backup.

### 7.6 Probar self-heal

```bash
# Borra un pod manualmente
kubectl delete pod -l app=openpanel-api -n openpanel

# Espera 30-60 segundos y verifica que ArgoCD lo recrea
kubectl get pods -l app=openpanel-api -n openpanel
# El pod debe haberse recreado automaticamente
```

### 7.7 Probar auto-sync

```bash
# Haz un cambio en un manifiesto (ej: cambia replicas de start a 2)
# Edita k8s/base/openpanel/start-deployment.yaml y cambia replicas: 1 a replicas: 2
git add k8s/base/openpanel/start-deployment.yaml
git commit -m "fix: scale start deployment to 2 replicas"
git push

# Espera 3 minutos (o configura webhook) y verifica
kubectl get pods -l app=openpanel-start -n openpanel
# Deberian ser 2 replicas
```

**Checkpoint:** ArgoCD UI accesible. 3 apps Synced y Healthy. Self-heal funcionando.

---

## Fase 8: Sealed Secrets

### 8.1 Instalar Sealed Secrets Controller

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/controller.yaml
kubectl wait --for=condition=ready pod -l name=sealed-secrets-controller -n kube-system --timeout=120s
```

### 8.2 Leer los valores actuales de los secrets

Antes de sellar, lee los valores reales que estan corriendo en el cluster:

```bash
kubectl get secret postgres-credentials -n openpanel -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k+'='+base64.b64decode(v).decode()) for k,v in d.items()]"
kubectl get secret redis-credentials -n openpanel -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k+'='+base64.b64decode(v).decode()) for k,v in d.items()]"
kubectl get secret clickhouse-credentials -n openpanel -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k+'='+base64.b64decode(v).decode()) for k,v in d.items()]"
kubectl get secret openpanel-secrets -n openpanel -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k+'='+base64.b64decode(v).decode()) for k,v in d.items()]"
```

Verifica los valores ANTES de sellar. En particular confirma que el pod de la API usa los mismos valores:
```bash
kubectl exec -n openpanel deployment/openpanel-api-blue -- env | grep -E "CLICKHOUSE|DATABASE|REDIS"
```

### 8.3 Crear Sealed Secrets con los valores reales

> **IMPORTANTE:** Usa los valores exactos que estan corriendo en el cluster, no los valores por defecto.
> La CLICKHOUSE_URL debe usar el usuario `openpanel`, no `default`.

```bash
# PostgreSQL
kubectl create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=openpanel \
  --from-literal=POSTGRES_PASSWORD=openpanel123 \
  -n openpanel --dry-run=client -o yaml | \
  kubeseal --format=yaml > k8s/argocd/sealed-secrets/postgres-credentials.yaml

# ClickHouse
kubectl create secret generic clickhouse-credentials \
  --from-literal=CLICKHOUSE_USER=openpanel \
  --from-literal=CLICKHOUSE_PASSWORD=openpanel123 \
  -n openpanel --dry-run=client -o yaml | \
  kubeseal --format=yaml > k8s/argocd/sealed-secrets/clickhouse-credentials.yaml

# Redis
kubectl create secret generic redis-credentials \
  --from-literal=REDIS_PASSWORD=openpanel123 \
  -n openpanel --dry-run=client -o yaml | \
  kubeseal --format=yaml > k8s/argocd/sealed-secrets/redis-credentials.yaml

# OpenPanel secrets — CLICKHOUSE_URL usa usuario "openpanel", no "default"
kubectl create secret generic openpanel-secrets \
  --from-literal=API_SECRET=super-secret-api-key-change-in-production \
  --from-literal=CLICKHOUSE_URL=http://openpanel:openpanel123@clickhouse:8123/openpanel \
  --from-literal=DATABASE_URL=postgresql://openpanel:openpanel123@postgres:5432/openpanel \
  --from-literal=REDIS_URL=redis://default:openpanel123@redis:6379 \
  -n openpanel --dry-run=client -o yaml | \
  kubeseal --format=yaml > k8s/argocd/sealed-secrets/openpanel-secrets.yaml
```

### 8.3 Aplicar los Sealed Secrets

```bash
kubectl apply -f k8s/argocd/sealed-secrets/
```

### 8.4 Verificar que los Secrets se crearon

```bash
kubectl get secrets -n openpanel
kubectl get secrets -n observability
kubectl get secrets -n backup
# Deben aparecer los secrets descifrados por el controller
```

### 8.5 Eliminar los secrets manuales de la Fase 4 y 5

```bash
# Los Sealed Secrets ya los han recreado, pero si hay duplicados:
# No hace falta eliminar nada — el SealedSecret controller sobrescribe
```

### 8.6 Commitear los Sealed Secrets (son seguros)

Los archivos en `k8s/argocd/sealed-secrets/` contienen los secretos cifrados con la clave
del controlador. Son seguros para subir a Git publico o privado.

```bash
git add k8s/argocd/sealed-secrets/
git commit -m "feat: add sealed secrets (encrypted, safe to commit)"
git push
```

**Checkpoint:** `kubectl get sealedsecrets -A` muestra todos los sealed secrets. Los Secrets reales existen en cada namespace.

---

## Fase 9: Observabilidad — Prometheus y Grafana

### 9.1 Verificar que el stack se desplego via ArgoCD

Si ArgoCD ya sincronizo la app `observability`:

```bash
kubectl get pods -n observability
# Deben estar: prometheus, grafana, loki, promtail (daemonset), tempo
```

Si no estan desplegados, aplica manualmente:

```bash
kubectl apply -k k8s/base/observability/
```

### 9.2 Verificar Prometheus

```bash
# Port-forward para acceso directo (alternativa al Ingress)
kubectl port-forward svc/prometheus 9090:9090 -n observability &

# Verificar targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
# Debe ser > 0

# O accede via navegador: http://prometheus.local
```

En Prometheus UI > Status > Targets: verificar que los targets de `kubernetes-pods` aparecen.

### 9.3 Verificar Grafana

```bash
# Accede via http://grafana.local
# Login: admin / (la password que generaste en Fase 8.2)

# O recuperala:
kubectl get secret grafana-admin-credentials -n observability -o jsonpath='{.data.admin-password}' | base64 -d
```

### 9.4 Verificar datasources en Grafana

En Grafana > Configuration > Data Sources:
- Prometheus (default) — Status: `Data source is working`
- Loki — Status: `Data source is working`
- Tempo — Status: `Data source is working`

> Si un datasource falla, verifica que el servicio correspondiente esta corriendo:
> `kubectl get svc -n observability`

### 9.5 Importar dashboards

En Grafana > Dashboards > Import:

1. **Kubernetes Cluster**: Importa el dashboard ID `6417` (pre-hecho por la comunidad)
2. **Node Exporter**: Dashboard ID `1860`
3. **OpenPanel Overview**: Crea uno manualmente con estos paneles:
   - Query rate: `rate(http_requests_total{namespace="openpanel"}[5m])`
   - Error rate: `rate(http_requests_total{namespace="openpanel",status=~"5.."}[5m])`
   - Latency P95: `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{namespace="openpanel"}[5m]))`
   - Pods running: `count(kube_pod_status_phase{namespace="openpanel",phase="Running"})`

### 9.6 Verificar alertas

En Prometheus UI > Alerts:
- Deben aparecer las 5 alertas definidas en `prometheus/configmap.yaml`
- Estado normal: `inactive` (no hay problemas activos)

**Checkpoint:** Grafana accesible con 3 datasources verdes. Dashboards con datos. Alertas visibles en Prometheus.

---

### 9.7 Exporters: metricas de Redis, PostgreSQL, ClickHouse y nodo

Esta seccion amplia el stack de observabilidad con exporters reales para obtener metricas
de bases de datos y del host en el dashboard de Grafana.

Los manifiestos ya estan configurados en el repositorio. Este es el resumen de lo que se añadio
y como verificarlo:

**Arquitectura de exporters:**

| Exporter | Patron | Puerto | Metricas clave |
|---|---|---|---|
| `redis_exporter` | Sidecar en el pod de Redis | 9121 | `redis_up`, `redis_connected_clients`, `redis_memory_used_bytes` |
| `postgres_exporter` | Sidecar en el pod de PostgreSQL | 9187 | `pg_up`, `pg_database_size_bytes`, `pg_stat_database_tup_fetched` |
| ClickHouse | Nativo via XML config | 9363 | `chi_clickhouse_*` (metricas internas de ClickHouse) |
| `node-exporter` | DaemonSet (un pod por nodo) | 9100 | `node_filesystem_avail_bytes`, CPU, memoria del host |

**Patron sidecar:** Los exporters de Redis y PostgreSQL comparten pod con la base de datos.
Al estar en el mismo pod, se comunican por `localhost` sin necesidad de exponer puertos extra al cluster.

**Verificar que los exporters estan corriendo:**

```bash
# Redis: debe ser 2/2 (redis + redis_exporter)
kubectl get pods -n openpanel -l app=redis
# Esperas: redis-<hash>   2/2   Running

# PostgreSQL: debe ser 2/2 (postgres + postgres_exporter)
kubectl get pods -n openpanel -l app=postgres
# Esperas: postgres-0   2/2   Running

# ClickHouse: 1/1 (metricas nativas, sin sidecar)
kubectl get pods -n openpanel -l app=clickhouse

# Node Exporter: 1 pod por nodo en observability
kubectl get pods -n observability -l app=node-exporter
```

**Verificar que Prometheus scrapea los nuevos targets:**

En el navegador: `http://prometheus.local/targets`

Busca estos jobs:
- `kubernetes-pods` — debe incluir instancias con port `9121`, `9187`, `9363`
- `node-exporter` — debe incluir el nodo con port `9100`

O via curl:
```bash
curl -s http://prometheus.local/api/v1/targets | \
  python3 -c "import sys,json; [print(t['labels']['job'], t['labels'].get('__address__',''), t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
```

**Dashboard Grafana — 18 paneles:**

El dashboard `OpenPanel - Kubernetes Monitoring` (uid: `openpanel-k8s`) tiene ahora 18 paneles:

| Fila | Paneles |
|---|---|
| Fila 1 (y=0) | Memory Usage by Pod (serie temporal), CPU Usage by Pod (serie temporal) |
| Fila 2 (y=8) | Memory Current (stat), Pods Running (stat), CPU Total (stat), Prometheus Targets UP (stat) |
| Fila 3 (y=12) | Memory by Pod History, CPU by Pod History |
| Fila 4 (y=20) | Redis UP, Redis Clients, Redis Memory, PostgreSQL UP, PostgreSQL DB Size, Node Disk Available |
| Fila 5 (y=24) | Redis Commands/sec, Redis Memory Over Time |
| Fila 6 (y=32) | PostgreSQL Rows Fetched/sec, Node Disk Usage % |

**Si el dashboard no muestra datos en los paneles de Redis/PostgreSQL/nodo:**

```bash
# Reiniciar Prometheus para que recargue la config
kubectl rollout restart deployment/prometheus -n observability

# Esperar
kubectl rollout status deployment/prometheus -n observability

# Si Prometheus crashea con "lock DB directory":
# El pod anterior no libero el lock. Borralo para forzar arranque limpio:
kubectl delete pod -n observability -l app=prometheus
kubectl rollout status deployment/prometheus -n observability
```

---

### Fixes aplicados en exporters (ya incorporados en los manifests)

| Problema | Causa | Solucion |
|---|---|---|
| `spec.selector` immutable al hacer `kubectl apply -k` | kustomize `commonLabels` anade label `project: openpanel` a selectors de Deployments ya creados sin ese label | `kubectl delete deployment redis openpanel-api-blue openpanel-api-green openpanel-start openpanel-worker -n openpanel` y volver a aplicar |
| StatefulSet `forbidden: updates to statefulset spec for fields other than replicas...` | kustomize `commonLabels` anade labels a `volumeClaimTemplates` que es inmutable | `kubectl delete statefulset postgres clickhouse -n openpanel --cascade=orphan` y volver a aplicar |
| Pods de StatefulSet siguen sin tener el sidecar despues de `--cascade=orphan` | `--cascade=orphan` borra el controlador pero no el pod — el pod huerfano no recibe el nuevo spec | `kubectl delete pod postgres-0 clickhouse-0 -n openpanel` — el StatefulSet recreado recrea el pod con el spec nuevo |
| Service de postgres/clickhouse con `Endpoints: <none>` | Los pods huerfanos no tenian el label `project: openpanel` que pedia el Service selector | Al recrear los pods (paso anterior), los pods nuevos reciben el spec completo con todos los labels |
| API en 503 despues de recrear StatefulSets | Consecuencia directa de postgres sin endpoints | Se resuelve al borrar y recrear los pods huerfanos |
| `InvalidImageName` en pods de API/start/worker | Imagenes con mayusculas `ghcr.io/RubenLopSol/` — GHCR requiere minusculas | Corregir a `ghcr.io/rubenlopsol/` en los 3 deployments |

---

## Fase 10: Observabilidad — Loki y Promtail

### 10.1 Verificar Promtail

```bash
kubectl get pods -n observability -l app=promtail
# Debe haber 1 pod (DaemonSet, 1 por nodo)

kubectl logs -n observability -l app=promtail --tail=20
# Debe mostrar que esta enviando logs a Loki
```

### 10.2 Verificar logs en Grafana

En Grafana > Explore > selecciona datasource Loki:

```
{namespace="openpanel"}
```

Deberian aparecer logs de los pods de openpanel.

Prueba queries mas especificas:

```
{namespace="openpanel", pod=~"openpanel-api.*"}
{namespace="openpanel", container="postgres"}
{namespace="openpanel"} |= "error"
```

### 10.3 Crear un dashboard de logs

En Grafana, crea un dashboard con paneles de Loki:
- Logs panel con `{namespace="openpanel"}`
- Stat panel: errores por hora `count_over_time({namespace="openpanel"} |= "error" [1h])`

**Checkpoint:** Logs de todos los pods visibles en Grafana via Loki.

---

## Fase 11: Observabilidad — Tempo

### 11.1 Verificar Tempo

```bash
kubectl get pods -n observability -l app=tempo
# Debe estar Running

kubectl logs -n observability -l app=tempo --tail=10
```

> **PROBLEMA CONOCIDO — Tempo latest incompatible:**
> Tempo v2.10.x (imagen `:latest`) requiere Kafka por defecto y falla con:
> `failed to create distributor: the Kafka topic has not been configured`
>
> Tambien el campo `compactor` y `metrics_generator` causan errores de parseo en algunas versiones.
>
> **Fix aplicado:** Pinear a `grafana/tempo:2.6.1` y simplificar el configmap:
> - `k8s/base/observability/tempo/deployment.yaml`: cambiar `grafana/tempo:latest` → `grafana/tempo:2.6.1`
> - `k8s/base/observability/tempo/configmap.yaml`: eliminar bloques `compactor` y `metrics_generator`
>
> ```bash
> kubectl apply -k k8s/base/observability/
> kubectl rollout restart deployment/tempo -n observability
> ```

### 11.2 Instrumentar la aplicacion

Para que Tempo reciba traces, la aplicacion necesita enviar telemetria. Opciones:

**Opcion A — Auto-instrumentacion (recomendada):**

Agrega las variables de entorno de OpenTelemetry al ConfigMap o a los deployments:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://tempo.observability.svc.cluster.local:4318"
  - name: OTEL_SERVICE_NAME
    value: "openpanel-api"  # o start, worker
  - name: OTEL_TRACES_EXPORTER
    value: "otlp"
```

> **Si modificas manifiestos o Dockerfiles para instrumentacion**, haz commit:
> ```bash
> git add k8s/base/openpanel/configmap.yaml  # o el deployment que hayas modificado
> git commit -m "feat: add OpenTelemetry env vars for tracing"
> git push
> ```

Luego, en el Dockerfile de la API, agrega el paquete de auto-instrumentacion de Node.js:

```dockerfile
RUN npm install @opentelemetry/auto-instrumentations-node
```

Y arranca con:

```bash
node --require @opentelemetry/auto-instrumentations-node/register app.js
```

**Opcion B — Sin instrumentacion del codigo:**

Si no quieres modificar los Dockerfiles, puedes usar un OpenTelemetry Collector que genere traces a partir de las metricas de Prometheus (service graphs). No tendras traces por peticion, pero Tempo estara funcionando y conectado. Documenta la decision.

### 11.3 Verificar correlacion en Grafana

Si tienes traces:
- En Grafana > Explore > Tempo: busca traces
- Desde un log en Loki con traceID, deberia saltar a Tempo
- Desde una traza en Tempo, deberia saltar a los logs en Loki

**Checkpoint:** Tempo corriendo y conectado como datasource en Grafana. Idealmente con traces visibles.

---

## Fase 12: Blue-Green Deployment

### 12.1 Preparar el deployment Green

El deployment green (`k8s/base/openpanel/api-deployment-green.yaml`) debe tener los mismos fixes que blue:
- `command: ["node", "dist/index.js"]` para evitar el wrapper dotenv
- Variables de entorno `HOME`, `COREPACK_HOME`, `XDG_CACHE_HOME` apuntando a `/tmp`
- VolumeMount y Volume para `/tmp` (emptyDir)

Despliega el deployment green:
```bash
kubectl apply -f k8s/base/openpanel/api-deployment-green.yaml
```

El deployment arranca con `replicas: 0` — el script lo escala durante el switch.

### 12.2 Ejecutar el script de switch

```bash
./scripts/blue-green-switch.sh
```

El script:
1. Detecta que Blue esta activo
2. Escala Green a 2 replicas
3. Espera health checks
4. Te pide confirmacion
5. Cambia el selector del Service
6. Te pregunta si escalar down Blue

### 12.3 Verificar el switch

```bash
# Ver que version esta activa
kubectl get svc openpanel-api -n openpanel -o jsonpath='{.spec.selector.version}'
# Debe decir "green"

# Verificar que la API responde
curl -s http://api.openpanel.local/health
```

### 12.4 Probar rollback

```bash
# Rollback instantaneo
kubectl patch svc openpanel-api -n openpanel -p '{"spec":{"selector":{"version":"blue"}}}'

# Verificar
kubectl get svc openpanel-api -n openpanel -o jsonpath='{.spec.selector.version}'
# Debe decir "blue"

curl -s http://api.openpanel.local/health
```

### 12.5 Documentar tiempos

Mide y documenta:
- Tiempo de switch: desde que ejecutas el script hasta que Green sirve trafico
- Tiempo de rollback: desde el patch hasta que Blue sirve trafico
- Objetivo: rollback < 30 segundos

**Checkpoint:** Switch Blue->Green y rollback Green->Blue funcionan. API responde en ambos casos.

---

## Fase 13: Backup con Velero y MinIO

### 13.1 Verificar MinIO

```bash
kubectl get pods -n backup -l app=minio
# Debe estar Running

# Port-forward para acceder a la consola de MinIO
kubectl port-forward svc/minio 9001:9001 -n backup &
# Accede a http://localhost:9001
```

### 13.2 Crear el bucket para Velero

```bash
MINIO_POD=$(kubectl get pod -n backup -l app=minio -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n backup ${MINIO_POD} -- mc alias set local http://localhost:9000 minioadmin $(kubectl get secret minio-credentials -n backup -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
kubectl exec -n backup ${MINIO_POD} -- mc mb local/velero-backups
```

### 13.3 Crear el archivo de credenciales de Velero

Crea el archivo `credentials-velero` en la raiz del proyecto (ya esta en `.gitignore` si seguiste la Fase 1.6):

```bash
# Recupera la password de MinIO que generaste en la Fase 8
MINIO_PASS=$(kubectl get secret minio-credentials -n backup -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)

# Crea el archivo de credenciales
cat > ~/Desktop/Master/proyecto_final/credentials-velero <<EOF
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = ${MINIO_PASS}
EOF

# Verificar que esta en .gitignore
grep "credentials-velero" .gitignore
# Debe devolver: credentials-velero
```

> IMPORTANTE: Nunca hagas `git add credentials-velero`. Este archivo tiene credenciales en texto plano.

### 13.4 Instalar Velero en el cluster

> **IMPORTANTE:** Velero se instala en su propio namespace `velero`, NO en `backup`.
> El namespace `backup` es para MinIO. El namespace `velero` es para el servidor de Velero.

```bash
cd ~/Desktop/Master/proyecto_final

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://minio.backup.svc.cluster.local:9000 \
  --namespace velero

# Verificar que el pod de Velero esta Running
kubectl get pods -n velero
# Deben aparecer: velero-<hash> y restic-<hash> (o solo velero si no hay restic)
```

### 13.5 Verificar BackupStorageLocation

```bash
# El BSL debe aparecer como Available (puede tardar 1-2 minutos)
velero backup-location get

# O con kubectl:
kubectl get backupstoragelocation -n velero
# PHASE debe ser Available
```

> Si aparece `Unavailable`, verifica que MinIO esta corriendo y que el bucket existe:
> ```bash
> kubectl get pods -n backup -l app=minio
> ```

### 13.6 Crear un backup manual

```bash
velero backup create backup-manual-openpanel \
  --include-namespaces openpanel,observability \
  --namespace velero

# Verificar que el backup se completo
velero backup describe backup-manual-openpanel --namespace velero
# Phase debe ser: Completed
# Items backed up: > 0
```

### 13.7 Probar restore

```bash
# Simula un desastre: borra el deployment de redis
kubectl delete deployment redis -n openpanel

# Verifica que desaparecio
kubectl get pods -n openpanel -l app=redis
# No debe aparecer nada

# Restaura desde el backup
velero restore create restore-test \
  --from-backup backup-manual-openpanel \
  --include-resources deployments \
  --namespace velero

# Espera a que complete
velero restore describe restore-test --namespace velero
# Phase: Completed

# Verifica que volvio
kubectl get pods -n openpanel -l app=redis
# Debe aparecer de nuevo
```

### 13.8 Aplicar schedules automaticos

```bash
# El archivo schedule.yaml usa namespace: velero (donde esta instalado Velero)
kubectl apply -f k8s/base/backup/velero/schedule.yaml

velero schedule get
# Deben aparecer:
# - daily-full-backup (cron: 0 2 * * *) — backup diario de openpanel + observability
# - hourly-database-backup (cron: 0 * * * *) — backup horario de pods con label backup=database
```

### 13.9 Backup de bases de datos (SQL dump)

```bash
./scripts/backup-restore.sh backup-db
# Genera un archivo backup-postgres-*.sql.gz local (ignorado por .gitignore)
```

**Checkpoint:** Backup manual exitoso con Phase=Completed. Restore verificado (objeto borrado y restaurado). Schedules `daily-full-backup` y `hourly-database-backup` configurados.

---

### Fixes aplicados en Fase 13 (ya incorporados)

| Problema | Causa | Solucion |
|---|---|---|
| `schedule.yaml` con `namespace: backup` falla | Velero esta instalado en namespace `velero`, no `backup` | Cambiar `namespace: backup` → `namespace: velero` en el Schedule CRD |
| `velero backup get -n backup` devuelve error | Velero no esta en ese namespace | Usar `velero backup get` sin `-n` o con `-n velero` |
| BackupStorageLocation en estado `Unavailable` | MinIO puede tardar en arrancar o el bucket no existe | Esperar 1-2 min y verificar que el bucket `velero-backups` fue creado en paso 13.2 |

---

## Fase 14: Documentacion final

> Esta es la fase donde se sube `docs/` a Git por primera vez.
> Escribes la documentacion DESPUES de haber implementado todo, con datos y capturas reales.

### 14.1 Documentos a crear

Crea estos archivos en `docs/`. Basate en lo que ya viviste implementando el proyecto:

| Archivo | Contenido |
|---|---|
| `docs/ARCHITECTURE.md` | Diagramas de arquitectura (app + infra), stack tecnologico, decisiones de diseno |
| `docs/SETUP.md` | Requisitos, instalacion de herramientas, bootstrap del cluster (resumen de Fase 0-3) |
| `docs/GITOPS.md` | Flujo GitOps, estructura del repo, como hacer cambios, sync policies |
| `docs/CICD.md` | Pipeline CI, pipeline CD, workflows, versionado, como hacer release |
| `docs/BLUE-GREEN.md` | Estrategia, proceso de deployment, script de switch, rollback |
| `docs/OBSERVABILITY.md` | Stack, dashboards, alertas, queries utiles, troubleshooting |
| `docs/BACKUP-RECOVERY.md` | Estrategia, schedules, procedures de restore, DR plan |
| `docs/SECURITY.md` | Secrets, network policies, RBAC, container security |
| `docs/OPERATIONS.md` | Comandos comunes, troubleshooting, escalado, updates |
| `docs/RUNBOOK.md` | Procedimientos operacionales, que hacer ante cada alerta |

### 14.2 Contenido minimo de cada documento

Cada documento debe tener:
- Titulo y descripcion breve
- Diagrama o tabla resumen
- Pasos/procedimientos concretos con comandos reales (no hipoteticos)
- Troubleshooting: problemas que encontraste tu y como los resolviste

### 14.3 Diagramas

Ya tienes los diagramas en `docs/diagrams/img/`. Referencia estos PNGs desde los documentos.
Los `.mmd` (fuentes Mermaid) tambien estan en `docs/diagrams/` — puedes editarlos si algo cambio.

### 14.4 Verificar y ampliar el README.md principal

El README.md de la raiz ya existe. Amplialo con links a cada documento de `docs/`:

```markdown
## Documentacion

- [Arquitectura](docs/ARCHITECTURE.md)
- [Setup](docs/SETUP.md)
- [GitOps](docs/GITOPS.md)
- ...
```

### 14.5 Commit de toda la documentacion (primer y unico commit de docs/)

```bash
cd ~/Desktop/Master/proyecto_final
git add docs/ README.md
git commit -m "docs: complete project documentation"
git push
```

> Este es el commit mas importante visualmente: demuestra que documentaste el proyecto
> una vez completado, con conocimiento real de lo que hiciste.

**Checkpoint:** Todos los .md en `docs/` creados con contenido real. `git log --oneline` muestra un historial limpio y logico.

---

## Fase 15: Validacion y entrega

### 15.1 Checklist de validacion completa

Recorre este checklist y marca cada punto. Todo debe funcionar:

**Infraestructura:**
```
[ ] Minikube cluster corriendo
[ ] 4 namespaces creados
[ ] Ingress controller operativo
[ ] DNS local configurado
[ ] Storage provisioner funcionando
[ ] Todos los PVCs bound
```

**Aplicacion:**
```
[ ] API pod Running
[ ] Start/Dashboard pod Running
[ ] Worker pod Running
[ ] PostgreSQL pod Running
[ ] ClickHouse pod Running
[ ] Redis pod Running
[ ] Health checks pasando
[ ] Ingress routing funcionando
[ ] App accesible en navegador
```

**GitOps:**
```
[ ] ArgoCD instalado y accesible
[ ] Repositorio Git conectado
[ ] 3 Applications sincronizadas
[ ] Auto-sync verificado
[ ] Self-heal verificado
```

**CI/CD:**
```
[ ] GitHub Actions workflow CI verde
[ ] Validacion de app (lint, test) pasando
[ ] Validacion de infra (kubeconform, kube-linter, hadolint) pasando
[ ] Build automatico funcionando
[ ] Security scanning (Trivy + Gitleaks) ejecutandose
[ ] Push a GHCR exitoso
[ ] CD actualiza manifests automaticamente
```

**Observabilidad:**
```
[ ] Prometheus recolectando metricas
[ ] Loki recibiendo logs
[ ] Tempo desplegado (y recibiendo traces si instrumentaste)
[ ] Grafana accesible con 3 datasources
[ ] Minimo 3 dashboards creados
[ ] 5 alertas configuradas
```

**Seguridad:**
```
[ ] Sealed Secrets controller instalado
[ ] Todos los secrets cifrados y commiteados
[ ] Network Policies aplicadas
[ ] Containers non-root
[ ] No hay secrets en texto plano en Git
```

**Blue-Green:**
```
[ ] Deployments blue y green existen
[ ] Switch funciona
[ ] Rollback verificado (< 30s)
```

**Backup:**
```
[ ] Velero instalado
[ ] MinIO corriendo
[ ] Backup manual exitoso
[ ] Restore verificado
[ ] Schedules automaticos configurados
```

**Documentacion:**
```
[ ] README.md completo
[ ] Todos los docs/ creados
[ ] Diagramas incluidos
[ ] Comandos utiles documentados
```

### 15.2 Limpieza final

```bash
# Verificar que no hay secrets en Git
grep -r "password\|secret\|token\|key" k8s/ --include="*.yaml" | grep -v "secretKeyRef\|SealedSecret\|sealed-secrets\|valueFrom\|secretRef\|name:"
# No deberia devolver nada con valores reales

# Verificar git status — no debe haber archivos sensibles sin trackear
git status
# Revisa que credentials-velero, .env, *.sql.gz no aparecen como "untracked" o "modified"

# Verificar historial de commits
git log --oneline
# Debe verse algo como:
# abc1234 docs: complete project documentation
# def5678 chore: update image tags to main-<SHA>   (varios, del CD automatico)
# ghi9012 feat: add sealed secrets (encrypted, safe to commit)
# jkl3456 fix: scale start deployment to 2 replicas
# mno7890 ci: trigger first pipeline run
# pqr1234 feat: add k8s manifests, CI/CD workflows and scripts
# stu5678 Initial commit: project structure
```

### 15.3 Verificar que no queda ningun placeholder

```bash
grep -r "TU_USUARIO\|GITHUB_USER\|TU_TOKEN\|TU_API_SECRET" k8s/ .github/ README.md
# No debe devolver nada
```

### 15.4 Si queda algun cambio pendiente, commitea con mensaje descriptivo

```bash
# Solo si hay algo pendiente que no se commiteo antes
git status
git add <archivos-especificos>
git commit -m "chore: final cleanup and adjustments"
git push
```

> No uses `git add -A` ni `git add .` — sé especifico para no incluir archivos sensibles accidentalmente.

### 15.4 Prueba de reproducibilidad

Si quieres ir un paso mas alla, destruye todo y recrea desde cero:

```bash
minikube delete -p openpanel
./scripts/setup-minikube.sh
./scripts/install-argocd.sh
kubectl apply -f k8s/argocd/projects/
kubectl apply -f k8s/argocd/applications/
# Espera a que ArgoCD sincronice todo
# Verifica que todo funciona
```

Si la app se levanta sola con estos comandos, tienes un proyecto reproducible.

---

## Resumen de fases

| Fases | Descripcion | Bloque | Estado |
|---|---|---|---|
| 0 | Instalar 4 herramientas (argocd, kubeseal, velero, gh) | Preparacion | ✅ Completado |
| 1 | Git init + GitHub repo + reemplazar GITHUB_USER | Preparacion | ✅ Completado |
| 2 | Construir imagenes Docker y subir a GHCR | Containerizacion | ✅ Completado |
| 3 | Levantar cluster Minikube + namespaces + DNS | Infra | ✅ Completado |
| 4 | Desplegar PostgreSQL, ClickHouse, Redis | Despliegue BD | ✅ Completado |
| 5 | Desplegar API, Dashboard, Worker + Ingress + Network Policies | Despliegue App | ✅ Completado |
| 6 | Verificar CI verde en GitHub Actions | CI/CD | ✅ Completado |
| 7 | Instalar ArgoCD + conectar repo + verificar sync | GitOps | ✅ Completado |
| 8 | Crear Sealed Secrets con kubeseal y commitearlos | Seguridad | ✅ Completado |
| 9 | Prometheus + Grafana + dashboards + alertas + exporters (18 paneles) | Observabilidad | ✅ Completado |
| 10 | Verificar Loki + Promtail + logs en Grafana | Observabilidad | ✅ Completado |
| 11 | Verificar Tempo + traces | Observabilidad | ✅ Completado |
| 12 | Probar Blue-Green switch + rollback | Despliegue avanzado | ✅ Completado |
| 13 | Instalar Velero + MinIO + backup + restore + schedules | Backup | ✅ Completado |
| 14 | Escribir documentacion final (10 documentos en docs/) | Documentacion | ⏳ Pendiente |
| 15 | Checklist completo + limpieza + entrega | Cierre | ⏳ Pendiente |

---

## Comandos de referencia rapida

```bash
# Estado general
kubectl get pods -A
kubectl get svc -A
kubectl get ingress -A
kubectl get pvc -A

# Logs de un pod
kubectl logs -f <pod> -n <namespace>

# ArgoCD
argocd app list
argocd app sync <app-name>
argocd app get <app-name>

# Minikube
minikube status -p openpanel
minikube dashboard -p openpanel
minikube tunnel -p openpanel  # si el ingress no resuelve

# Blue-Green
kubectl get svc openpanel-api -n openpanel -o jsonpath='{.spec.selector.version}'

# Velero (instalado en namespace velero)
velero backup get
velero restore get
velero schedule get
velero backup-location get
```
