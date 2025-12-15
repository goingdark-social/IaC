# CloudNativePG Disaster Recovery Guide

This document describes disaster recovery (DR) procedures for the Mastodon PostgreSQL database managed by CloudNativePG.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Backup Infrastructure](#backup-infrastructure)
- [Disaster Recovery Scenarios](#disaster-recovery-scenarios)
- [Recovery Procedures](#recovery-procedures)
  - [Latest Backup Recovery](#latest-backup-recovery)
- [Verification Procedures](#verification-procedures)
- [Troubleshooting](#troubleshooting)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Primary Kubernetes Cluster                       │
│                                                                       │
│  ┌───────────────────┐    WAL Archive    ┌────────────────────────┐ │
│  │  database-cnpg    │ ─────────────────▶│   Cloudflare R2 (S3)   │ │
│  │  (Primary)        │                   │   mastovault bucket    │ │
│  │                   │   Base Backups    │                        │ │
│  │  - 1+ instance    │ ─────────────────▶│  /cnpg/mastodon-db     │ │
│  │  - PostgreSQL 17  │   (Daily @ 06:00) │    ├── base/           │ │
│  └───────────────────┘                   │    └── wals/           │ │
│                                          └────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

## Backup Infrastructure

### Current Configuration

| Component | Value |
|-----------|-------|
| **Backup Storage** | Cloudflare R2 (S3-compatible) |
| **Bucket** | `mastovault` |
| **Path** | `s3://mastovault/cnpg/mastodon-database` |
| **WAL Archiving** | Enabled with gzip compression |
| **WAL Parallelism** | 8 concurrent uploads |
| **Base Backup Schedule** | Daily at 06:00 UTC |
| **Retention Policy** | 14 days |
| **Backup Method** | barman-cloud plugin |

### Server Identity

`serverName` is the logical identity of the cluster in Barman. Recovery **must** reference the original `serverName`. Recovered clusters must use a different destination path unless the original cluster is permanently gone.

> **WARNING**: Reusing a destinationPath with a different serverName will block recovery.

### Backup Verification

```bash
# List available backups - must return at least one base backup
kubectl exec -it database-cnpg-1 -n mastodon -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database \
  database-cnpg

# Verify WAL files exist in the archive path
# (Check that the path contains .ready files and WAL segments)
```

Backups are not considered valid until a test recovery has completed successfully.

## Disaster Recovery Scenarios

### When to Use Recovery

| Scenario | Method | Data Loss |
|----------|--------|-----------|
| Complete cluster loss | Full recovery | Since last WAL |

## Recovery Procedures

### Prerequisites: Create ObjectStore Resource

Before recovery, ensure the `ObjectStore` resource exists to define the backup source:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: database-backup
  namespace: mastodon
spec:
  configuration:
    destinationPath: s3://mastovault/cnpg/mastodon-database
    s3Credentials:
      accessKeyId:
        name: mastodon-walg-s3
        key: AWS_ACCESS_KEY_ID
      secretAccessKey:
        name: mastodon-walg-s3
        key: AWS_SECRET_ACCESS_KEY
    endpointURL: https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com
    wal:
      maxParallel: 8
```

Apply this manifest:

```bash
kubectl apply -f objectstore.yaml -n mastodon
```

### Latest Backup Recovery

Use this when you need to **restore to the most recent state** after complete data loss.

#### Step 1: Scale Down Applications

```bash
kubectl scale deployment -n mastodon \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  --replicas=0
```

#### Step 2: Prepare Recovery Manifest

Create `recovery-cluster.yaml` with the following content:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: database-cnpg-recovered
  namespace: mastodon
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17

  superuserSecret:
    name: database-cnpg-superuser

  storage:
    size: 50Gi
    storageClass: hcloud-volumes

  bootstrap:
    recovery:
      source: backup-source
      # No recoveryTarget = recover to latest available WAL

  externalClusters:
    - name: backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: database-backup
          serverName: database-cnpg  # Must match original cluster name

  postgresql:
    parameters:
      shared_preload_libraries: "pg_stat_statements"
    pg_hba:
      - host all all 0.0.0.0/0 md5
```

#### Step 3: Apply Recovery Cluster

```bash
kubectl apply -f recovery-cluster.yaml -n mastodon
kubectl get cluster database-cnpg-recovered -n mastodon -w
```

#### Step 4: Monitor Recovery

```bash
kubectl logs -f database-cnpg-recovered-1 -n mastodon -c postgres
```

#### Step 5: Switch to Recovered Cluster

Once recovery completes, update application configurations to use the new cluster and scale up applications.

## Verification Procedures

### Pre-Recovery Checks

```bash
# 1. Verify backup accessibility
kubectl exec -it database-cnpg-1 -n mastodon -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database \
  database-cnpg

# 2. Check current cluster status
kubectl get cluster -n mastodon

# 3. Verify secrets exist
kubectl get secret mastodon-walg-s3 -n mastodon
kubectl get secret database-cnpg-app -n mastodon
kubectl get secret database-cnpg-superuser -n mastodon
```

### Post-Recovery Validation

```bash
# 1. Check cluster is healthy
kubectl describe cluster database-cnpg-recovered -n mastodon

# 2. Verify database connectivity
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -c "SELECT version();"

# 3. Check data integrity
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -d mastodon_production -c "
    SELECT
      (SELECT COUNT(*) FROM accounts) as accounts,
      (SELECT COUNT(*) FROM statuses) as statuses,
      (SELECT COUNT(*) FROM users) as users;
  "

# 4. Verify recovery completion
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -c "SELECT pg_is_in_recovery();"  # Must return false

# 5. Check operator logs show WAL replay completion
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=50

# 6. Verify superuser and app roles exist
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -c "SELECT rolname FROM pg_roles WHERE rolname IN ('postgres', 'app');"

# 7. Verify application connectivity
kubectl run psql-test --rm -it --image=postgres:17 -- \
  psql "postgresql://app:password@database-cnpg-recovered-rw.mastodon:5432/mastodon_production" \
  -c "SELECT 1;"
```

If recovery does not exit recovery mode, do not reconnect applications.

## Troubleshooting

### Common Issues

#### Backup List Returns Empty

```bash
# Check credentials
kubectl get secret mastodon-walg-s3 -n mastodon -o yaml

# Verify endpoint URL
kubectl describe objectstore database-backup -n mastodon
```

#### Recovery Stuck in "Setting up primary"

```bash
# Check for WAL archive errors
kubectl logs database-cnpg-recovered-1-join -n mastodon

# Verify the serverName matches the original cluster
kubectl describe cluster database-cnpg-recovered -n mastodon
```

#### "WAL archive check failed" Error

This happens when the destination path already contains data from another cluster. CloudNativePG includes a safety check to prevent overwriting existing backups.

If you must recover to a path with existing data (not recommended), add this annotation to the cluster:

```yaml
metadata:
  annotations:
    cnpg.io/skipEmptyWalArchiveCheck: "enabled"
```

**WARNING**: This bypasses safety checks and can lead to data loss. Only use in expert scenarios.

### Getting Help

1. Check CloudNativePG documentation: https://cloudnative-pg.io/documentation/
2. Review operator logs: `kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg`
3. Check PostgreSQL logs: `kubectl logs <cluster>-1 -n mastodon -c postgres`

## References

- [CloudNativePG Backup and Recovery](https://cloudnative-pg.io/documentation/current/backup_recovery/)
- [Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/)
- [PostgreSQL Recovery Documentation](https://www.postgresql.org/docs/current/continuous-archiving.html)

