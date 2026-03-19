# Blue-Green Deployment — Estrategia de Despliegue sin Interrupciones

**Proyecto Final — Master DevOps & Cloud Computing**

---

## Qué es Blue-Green y por qué para la API

La estrategia Blue-Green mantiene **dos versiones del deployment** activas simultáneamente:

- **Blue** — versión actualmente en producción, recibe todo el tráfico
- **Green** — nueva versión candidata, desplegada y verificada antes de recibir tráfico

La conmutación se realiza cambiando el **selector del Service** de Kubernetes, lo que redirige el tráfico de forma instantánea sin interrupciones.

Se aplica únicamente al servicio **API** porque es el componente más crítico: es el punto de entrada de todos los eventos de analítica y atiende las peticiones del Dashboard.

![Blue-Green API](../diagrams/img/OpenPanel_API_Blue-Green%20.png)

---

## Arquitectura de los Manifiestos

### Dos Deployments simultáneos

```
k8s/base/openpanel/
├── api-deployment-blue.yaml    ← versión Blue (activa)
├── api-deployment-green.yaml   ← versión Green (standby)
└── api-service.yaml            ← Service (selector apunta a Blue o Green)
```

### Deployment Blue

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openpanel-api-blue
  namespace: openpanel
spec:
  replicas: 2
  selector:
    matchLabels:
      app: openpanel-api
      version: blue
  template:
    metadata:
      labels:
        app: openpanel-api
        version: blue
    spec:
      containers:
        - name: api
          image: ghcr.io/rubenlopsol/openpanel-api:main-dfc2ddf
```

### Deployment Green

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openpanel-api-green
  namespace: openpanel
spec:
  replicas: 0   ← En standby cuando no está activo
  selector:
    matchLabels:
      app: openpanel-api
      version: green
```

### Service (selector activo)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openpanel-api
  namespace: openpanel
spec:
  selector:
    app: openpanel-api
    version: blue    ← ← ← este es el switch
  ports:
    - port: 3000
      targetPort: 3000
```

---

## Script de Conmutación — `blue-green-switch.sh`

El repositorio incluye un script que automatiza todo el proceso de conmutación con validaciones de salud integradas:

```bash
./scripts/blue-green-switch.sh
```

El script detecta automáticamente la versión activa y ejecuta los siguientes pasos en orden:

| Paso | Acción |
|---|---|
| 1 | Detecta la versión activa actual (Blue o Green) |
| 2 | Escala el deployment destino a 2 réplicas |
| 3 | Espera a que el rollout complete (`--timeout=300s`) |
| 4 | Verifica que todos los pods destino estén en estado `Running` y `Ready` |
| 5 | Pide confirmación antes de conmutar el tráfico |
| 6 | Actualiza el selector del Service con `kubectl patch` |
| 7 | Muestra los endpoints activos para confirmar la conmutación |
| 8 | Pregunta si escalar a 0 el deployment antiguo (opcional, para rollback rápido) |

Si el health check del paso 4 falla, el script **aborta automáticamente** y escala el deployment destino a 0, sin haber tocado el tráfico en ningún momento.

Al finalizar, imprime el comando de rollback instantáneo por si fuera necesario.

---

## Flujo de Despliegue Blue-Green

### Situación inicial
- Blue está activo con la versión `v1.0` y recibe todo el tráfico
- Green tiene `replicas: 0` (no consume recursos)

### Paso 1 — El CD actualiza la imagen en Green

El pipeline CD actualiza el tag en `api-deployment-green.yaml`:

```bash
# CD pipeline actualiza el tag en Green
image: ghcr.io/rubenlopsol/openpanel-api:main-abc1234
```

ArgoCD despliega la nueva versión en Green.

### Paso 2 — Escalar Green y verificar

```bash
# Escalar Green para que arranque la nueva versión
kubectl scale deployment openpanel-api-green \
  -n openpanel --replicas=2

# Verificar que los pods Green están Running
kubectl get pods -n openpanel -l version=green

# Verificar logs (buscar errores de arranque)
kubectl logs -n openpanel -l version=green --tail=50

# Test rápido de salud (port-forward al pod Green directamente)
kubectl port-forward -n openpanel \
  deployment/openpanel-api-green 3001:3000
curl http://localhost:3001/health
```

### Paso 3 — Conmutar el tráfico a Green

```bash
# Cambiar el selector del Service a Green
kubectl patch service openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"green"}}}'

# Verificar que el Service apunta a Green
kubectl get service openpanel-api -n openpanel \
  -o jsonpath='{.spec.selector}'
```

### Paso 4 — Verificar la conmutación

```bash
# Verificar endpoints del Service (deben ser los pods Green)
kubectl get endpoints openpanel-api -n openpanel

# Monitorizar métricas en Grafana (tasa de errores, latencia)
# Dashboard: OpenPanel K8s Monitoring → "API Request Rate"
```

### Paso 5 — Limpiar Blue (opcional)

Una vez confirmado que Green funciona correctamente:

```bash
# Reducir Blue a 0 réplicas para liberar recursos
kubectl scale deployment openpanel-api-blue \
  -n openpanel --replicas=0
```

---

## Rollback

Si se detecta un problema en la nueva versión, el rollback es inmediato:

```bash
# Volver el tráfico a Blue con un solo comando
kubectl patch service openpanel-api -n openpanel \
  -p '{"spec":{"selector":{"app":"openpanel-api","version":"blue"}}}'
```

El rollback tarda **menos de 5 segundos** — no requiere redespliegue ni esperar a que arranquen nuevos pods (Blue ya estaba corriendo).

---

## Integración con ArgoCD

En el modelo GitOps, el cambio del selector del Service debe también reflejarse en Git:

```bash
# Editar api-service.yaml en el repositorio
# Cambiar: version: blue → version: green
git add k8s/base/openpanel/api-service.yaml
git commit -m "feat: switch API traffic to green (v1.2.0)"
git push
# ArgoCD aplica el cambio automáticamente
```

Para el rollback vía GitOps:

```bash
# Revertir el commit del Service
git revert HEAD
git push
# ArgoCD restaura el selector a Blue
```

---

## Resumen de Comandos

| Acción | Comando |
|---|---|
| Ver versión activa | `kubectl get svc openpanel-api -n openpanel -o jsonpath='{.spec.selector.version}'` |
| Escalar Green | `kubectl scale deployment openpanel-api-green -n openpanel --replicas=2` |
| Conmutar a Green | `kubectl patch svc openpanel-api -n openpanel -p '{"spec":{"selector":{"version":"green"}}}'` |
| Rollback a Blue | `kubectl patch svc openpanel-api -n openpanel -p '{"spec":{"selector":{"version":"blue"}}}'` |
| Ver pods por versión | `kubectl get pods -n openpanel -l version=blue` |
