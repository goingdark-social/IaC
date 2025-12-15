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

### Prerequisites: Create ObjectStore Resources

Before recovery, ensure the `ObjectStore` resources exist:

1. **For recovery source** (references the original cluster's backups):
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

2. **For recovered cluster backups** (new path to avoid conflicts):
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: database-backup-recovered
  namespace: mastodon
spec:
  configuration:
    destinationPath: 's3://mastovault/cnpg/mastodon-database-recovered'
    endpointURL: 'https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com'
    s3Credentials:
      accessKeyId:
        name: mastodon-walg-s3
        key: AWS_ACCESS_KEY_ID
      secretAccessKey:
        name: mastodon-walg-s3
        key: AWS_SECRET_ACCESS_KEY
    wal:
      compression: gzip
      maxParallel: 8
    data:
      compression: gzip
      jobs: 2
  retentionPolicy: "14d"
```

Apply these manifests:

```bash
kubectl apply -f objectstore-recovery.yaml -n mastodon
kubectl apply -f objectstore-recovered.yaml -n mastodon
```

**Important**: The recovered cluster uses a different `destinationPath` and `serverName` to avoid overwriting the original cluster's backups. CloudNativePG includes safety checks to prevent conflicts.

### Latest Backup Recovery

Use this when you need to **restore to the most recent state** after complete data loss.

#### Critical: Service Switching Strategy

The recovered cluster uses **different service names** to allow testing alongside the original:

- **Original cluster services**:
  - `database-cnpg-rw.mastodon:5432` (pooled via PgBouncer)
  - `database-cnpg.mastodon:5432` (direct connection to cluster)
- **Recovered cluster services**:
  - `database-cnpg-recovered-rw.mastodon:5432` (pooled via PgBouncer)
  - `database-cnpg-recovered.mastodon:5432` (direct connection to cluster)

**Applications connect via the pooler service** (`*-rw`). This is the **only connection string** you need to update when switching. All pooling, SSL, and connection management is automatic.

#### Option A: Full Disaster Recovery (Production Switchover)

**When to use**: When the primary cluster is lost and you need to restore production immediately.

##### Step 1: Scale Down Applications

```bash
kubectl scale deployment -n mastodon \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  --replicas=0
```

##### Step 2: Delete Original Cluster (if unrecoverable)

```bash
kubectl delete cluster database-cnpg -n mastodon
```

##### Step 3: Apply Recovery Cluster

```bash
kubectl apply -f recovery-cluster.yaml -n mastodon
kubectl get cluster database-cnpg-recovered -n mastodon -w
```

Wait for cluster status to show `Cluster is ready` and pooler to be healthy.

##### Step 4: Verify Recovered Cluster

```bash
# Check cluster is out of recovery
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -c "SELECT pg_is_in_recovery();"  # Should return false (f)

# Test connection via pooler
kubectl run psql-test --rm -it --image=postgres:17 -- \
  psql "postgresql://app:password@database-cnpg-recovered-rw.mastodon:5432/mastodon_production" \
  -c "SELECT COUNT(*) FROM accounts;"

# Verify data integrity - check key tables
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -d mastodon_production -c "
    SELECT
      (SELECT COUNT(*) FROM accounts) as accounts,
      (SELECT COUNT(*) FROM statuses) as statuses,
      (SELECT COUNT(*) FROM users) as users;
  "
```

##### Step 5: Update Application Database Connection

Update the ConfigMap/Secret containing `DATABASE_URL`:

```bash
# Edit the mastodon-db-url secret
kubectl edit secret mastodon-db-url -n mastodon
```

Change:
```
postgresql://app:password@database-cnpg-rw.mastodon:5432/mastodon_production
```

To:
```
postgresql://app:password@database-cnpg-recovered-rw.mastodon:5432/mastodon_production
```

##### Step 6: Scale Up Applications

```bash
kubectl scale deployment -n mastodon \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  --replicas=<original-count>
```

Monitor the rollout:

```bash
kubectl rollout status deployment/mastodon-web -n mastodon
kubectl rollout status deployment/mastodon-streaming -n mastodon
```

##### Step 7 (Optional): Rename for Permanence

Once verified stable for 24+ hours, rename the recovered cluster to match the original name:

```bash
# Export the recovered cluster
kubectl get cluster database-cnpg-recovered -n mastodon -o yaml > temp-recovered.yaml

# Edit and rename all instances of:
# - Cluster name: database-cnpg-recovered → database-cnpg
# - Pooler name: database-cnpg-recovered-pooler-rw → database-cnpg-pooler-rw
# - Service names to match
# Save as: recovered-cluster-renamed.yaml

# Delete old resources
kubectl delete cluster database-cnpg-recovered -n mastodon

# Apply renamed resources
kubectl apply -f recovered-cluster-renamed.yaml

# Update connection string back to original
kubectl edit secret mastodon-db-url -n mastodon
# Change to: postgresql://app:password@database-cnpg-rw.mastodon:5432/mastodon_production
```

#### Option B: Parallel Recovery (Testing/Safe Switchover)

**When to use**: When you want to test recovery or perform a safe switchover without disrupting the running cluster.

##### Step 1: Apply Recovery Cluster Alongside Running Cluster

```bash
kubectl apply -f recovery-cluster.yaml -n mastodon
kubectl get cluster database-cnpg-recovered -n mastodon -w
```

**Safety Notes**:
- ✅ Safe to run alongside the original cluster
- ✅ Recovery reads from backup storage, not the live cluster
- ✅ Uses separate backup paths to avoid conflicts
- ✅ Applications can test against recovered data
- ⚠️ Consumes additional resources (CPU, memory, storage)
- ⚠️ Data will be as of the last backup (potential data loss since backup time)

##### Step 2: Verify Recovered Cluster

```bash
# Check cluster is out of recovery
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -c "SELECT pg_is_in_recovery();"  # Should return false

# Test pooler connectivity
kubectl run psql-test --rm -it --image=postgres:17 -- \
  psql "postgresql://app:password@database-cnpg-recovered-rw.mastodon:5432/mastodon_production" \
  -c "SELECT COUNT(*) FROM accounts;"
```

##### Step 3: Validate Data Integrity

Before switching production, validate data:

```bash
# Compare row counts between original and recovered
kubectl exec -it database-cnpg-1 -n mastodon -c postgres -- psql -d mastodon_production -c "
  SELECT
    (SELECT COUNT(*) FROM accounts) as accounts,
    (SELECT COUNT(*) FROM statuses) as statuses,
    (SELECT COUNT(*) FROM users) as users;"

# Do same check on recovered cluster - results should match
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- psql -d mastodon_production -c "..."
```

##### Step 4: When Ready to Switch

Once you've validated the recovered cluster, follow **Option A steps 5-7** to switch production traffic.

#### Common Steps for Both Options

##### Monitor Recovery Progress

```bash
kubectl logs -f database-cnpg-recovered-1 -n mastodon -c postgres
```

Watch for:
- `Recovering with wal_level=replica`
- `Database system is ready to accept connections`
- Recovery completion messages

**Note**: The recovered cluster will automatically start archiving WAL files and taking backups to the new ObjectStore path, ensuring continuous protection.

## Pre-Switchover Validation Checklist

Before switching production traffic to the recovered cluster, verify all components:

```bash
# 1. Cluster health
kubectl get cluster database-cnpg-recovered -n mastodon -o wide

# 2. Pooler is running and healthy
kubectl get pooler database-cnpg-recovered-pooler-rw -n mastodon -o wide
kubectl get pods -l cnpg.io/pooler=database-cnpg-recovered-pooler-rw -n mastodon

# 3. Services are accessible
kubectl get svc database-cnpg-recovered-rw -n mastodon
kubectl get svc database-cnpg-recovered -n mastodon

# 4. Database is accepting connections
kubectl run psql-test --rm -it --image=postgres:17 -- \
  psql "postgresql://app:password@database-cnpg-recovered-rw.mastodon:5432/mastodon_production" \
  -c "SELECT version();"

# 5. All expected tables exist
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -d mastodon_production -c "\dt" | head -20

# 6. Data is not in recovery mode
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  psql -c "SELECT pg_is_in_recovery();"  # Must show: false

# 7. Application can connect with actual credentials
# Test with real mastodon-db-url secret from the environment
kubectl run test-mastodon --rm -it --image=postgres:17 -e DB_URL="$DB_URL" -- \
  psql "$DB_URL" -c "SELECT COUNT(*) FROM accounts;"
```

All checks must pass before proceeding with production traffic switch.

## Post-Switchover Validation

After switching production traffic to the recovered cluster, verify functionality:

```bash
# 1. Applications are running and healthy
kubectl get pods -n mastodon -l app=mastodon-web
kubectl get pods -n mastodon -l app=mastodon-streaming

# 2. Check for database connection errors in logs
kubectl logs -f deployment/mastodon-web -n mastodon --all-containers=true | grep -i "error\|failed\|connection"

# 3. Sidekiq workers are processing jobs normally
kubectl logs deployment/mastodon-sidekiq-default -n mastodon | grep -i "job\|processed"

# 4. Pooler is handling connections
kubectl logs deployment/database-cnpg-recovered-pooler-rw -n mastodon | tail -30

# 5. Monitor application health endpoints
kubectl port-forward svc/mastodon-web 3000:3000 -n mastodon
# In another terminal: curl http://localhost:3000/api/v1/instance
```

Monitor for at least 15-30 minutes before considering recovery complete.

## Recovery Validation Scripts

### Quick Health Check

```bash
#!/bin/bash
# quick-health-check.sh

CLUSTER="database-cnpg-recovered"
NAMESPACE="mastodon"

echo "=== Cluster Status ==="
kubectl get cluster $CLUSTER -n $NAMESPACE -o wide

echo "=== Pooler Status ==="
kubectl get pooler ${CLUSTER}-pooler-rw -n $NAMESPACE
kubectl get pods -l cnpg.io/pooler=${CLUSTER}-pooler-rw -n $NAMESPACE

echo "=== Database Ready ==="
kubectl exec -it ${CLUSTER}-1 -n $NAMESPACE -c postgres -- \
  psql -c "SELECT version();"

echo "=== Recovery Status ==="
kubectl exec -it ${CLUSTER}-1 -n $NAMESPACE -c postgres -- \
  psql -c "SELECT pg_is_in_recovery();"

echo "=== Data Integrity ==="
kubectl exec -it ${CLUSTER}-1 -n $NAMESPACE -c postgres -- \
  psql -d mastodon_production -c \
  "SELECT (SELECT COUNT(*) FROM accounts) as accounts, (SELECT COUNT(*) FROM statuses) as statuses;"
```

## Post-Recovery Backup Verification

The recovered cluster creates backups to **`s3://mastovault/cnpg/mastodon-database-recovered`** (separate from original). Verify:

```bash
# Check that backups are being created
kubectl logs -f deployment/database-cnpg-recovered-1 -n mastodon -c postgres | grep "Barman"

# List backups for recovered cluster
kubectl exec -it database-cnpg-recovered-1 -n mastodon -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database-recovered \
  database-cnpg-recovered
```

Backups should appear within 24 hours (depends on backup schedule).

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

