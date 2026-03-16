# Sealed Secrets

This directory contains encrypted SealedSecret resources.
These files are safe to commit to Git — only the Sealed Secrets controller
in the cluster can decrypt them.

## How to create a sealed secret

```bash
# 1. Create a regular Kubernetes secret (dry-run, not applied)
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --namespace=openpanel \
  --dry-run=client -o yaml > /tmp/secret.yaml

# 2. Seal it with kubeseal
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /tmp/secret.yaml > my-sealed-secret.yaml

# 3. Clean up the plaintext secret
rm /tmp/secret.yaml

# 4. Commit the sealed secret
git add my-sealed-secret.yaml
git commit -m "Add sealed secret for my-secret"
```

## Required sealed secrets for this project

- `openpanel-secrets.yaml` — API_SECRET, JWT_SECRET
- `postgres-credentials.yaml` — POSTGRES_USER, POSTGRES_PASSWORD
- `clickhouse-credentials.yaml` — CLICKHOUSE_USER, CLICKHOUSE_PASSWORD
- `redis-credentials.yaml` — REDIS_PASSWORD
- `grafana-admin-credentials.yaml` — admin-user, admin-password
- `minio-credentials.yaml` — MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
