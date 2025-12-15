# CloudNativePG Disaster Recovery Guide

This document describes disaster recovery (DR) procedures for the Mastodon PostgreSQL database managed by CloudNativePG.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Backup Infrastructure](#backup-infrastructure)
- [Disaster Recovery Scenarios](#disaster-recovery-scenarios)
- [Recovery Procedures](#recovery-procedures)
  - [Scenario 1: Hot Standby (Replica Cluster)](#scenario-1-hot-standby-replica-cluster)
  - [Scenario 2: Point-in-Time Recovery](#scenario-2-point-in-time-recovery)
  - [Scenario 3: Latest Backup Recovery](#scenario-3-latest-backup-recovery)
- [Verification Procedures](#verification-procedures)
- [Failback Procedures](#failback-procedures)
- [Testing DR Procedures](#testing-dr-procedures)
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
│                                                      │               │
│  ┌───────────────────┐                              │               │
│  │ database-cnpg-    │◀─────── WAL Streaming ───────┘               │
│  │ replica (Optional)│                                              │
│  │  (DR Standby)     │                                              │
│  └───────────────────┘                                              │
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

### Backup Verification

```bash
# List available backups
kubectl exec -it database-cnpg-1 -n goingdark-social -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database \
  database-cnpg

# Check WAL archive status
kubectl exec -it database-cnpg-1 -n goingdark-social -c postgres -- \
  barman-cloud-wal-archive --help
```

### Recovery Point Objective (RPO)

- **Theoretical RPO**: ~5 minutes (PostgreSQL `archive_timeout` default)
- **Practical RPO**: Near real-time with continuous WAL archiving
- **Base Backup RPO**: 24 hours maximum (daily backups)

### Recovery Time Objective (RTO)

| Scenario | Estimated RTO |
|----------|---------------|
| Replica promotion | 1-5 minutes |
| PITR (small DB) | 10-30 minutes |
| Full restore (20GB) | 30-60 minutes |

## Disaster Recovery Scenarios

### When to Use Each Recovery Method

| Scenario | Method | RTO | Data Loss |
|----------|--------|-----|-----------|
| Primary pod crash | Automatic failover | Seconds | None |
| Node failure | Automatic pod rescheduling | Minutes | None |
| Data corruption | PITR | 30+ min | Up to target time |
| Accidental deletion | PITR | 30+ min | Up to target time |
| Complete cluster loss | Full recovery | 30+ min | Since last WAL |
| Region failure | Replica promotion | 1-5 min | Minimal |

## Recovery Procedures

### Scenario 1: Hot Standby (Replica Cluster)

Use this for **continuous disaster recovery** with minimal data loss.

#### Step 1: Deploy Replica Cluster

```bash
# Apply the replica cluster manifest
kubectl apply -f disaster-recovery/replica-cluster.yaml -n goingdark-social

# Monitor replica status
kubectl get cluster database-cnpg-replica -n goingdark-social -w

# Check replication lag
kubectl exec -it database-cnpg-replica-1 -n goingdark-social -c postgres -- \
  psql -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

#### Step 2: Monitor Replica Health

```bash
# Check cluster status
kubectl describe cluster database-cnpg-replica -n goingdark-social

# Verify WAL receiver is running
kubectl exec -it database-cnpg-replica-1 -n goingdark-social -c postgres -- \
  psql -c "SELECT status, receive_start_lsn, latest_end_lsn FROM pg_stat_wal_receiver;"
```

#### Step 3: Promote Replica (Failover)

**⚠️ WARNING: This is irreversible. Only promote during actual disaster.**

```bash
# Option 1: Apply the promotion patch
kubectl patch cluster database-cnpg-replica -n goingdark-social \
  --type merge \
  --patch '{"spec":{"replica":{"enabled":false}}}'

# Option 2: Use the patch file
kubectl patch cluster database-cnpg-replica -n goingdark-social \
  --type merge \
  --patch-file disaster-recovery/promotion-patch.yaml

# Verify promotion
kubectl get cluster database-cnpg-replica -n goingdark-social
```

#### Step 4: Update Application Connections

After promotion, update connection strings to point to the new primary:

```bash
# Get the new service endpoint
kubectl get svc -n goingdark-social | grep database-cnpg-replica

# Update application ConfigMaps or secrets to use:
# - database-cnpg-replica-rw (read-write)
# - database-cnpg-replica-ro (read-only)
```

### Scenario 2: Point-in-Time Recovery

Use this to **recover to a specific point in time** (e.g., before data corruption).

#### Step 1: Identify Target Recovery Time

```bash
# Check available backups to determine recovery window
kubectl exec -it database-cnpg-1 -n goingdark-social -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database \
  database-cnpg

# Note the backup times - you can recover to any point AFTER the oldest backup
# but BEFORE the current time
```

#### Step 2: Prepare Recovery Manifest

Edit `disaster-recovery/recovery-cluster.yaml` and set the target time:

```yaml
spec:
  bootstrap:
    recovery:
      source: backup-source
      recoveryTarget:
        # Set to the desired recovery point (UTC)
        targetTime: "2024-12-15T12:00:00Z"
```

#### Step 3: Scale Down Applications

```bash
# Scale down all Mastodon components to prevent database connections
kubectl scale deployment -n goingdark-social \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  --replicas=0

# Scale down connection pooler
kubectl scale deployment -n goingdark-social database-cnpg-pooler-rw --replicas=0
```

#### Step 4: Apply Recovery Cluster

```bash
# Apply the recovery cluster manifest
kubectl apply -f disaster-recovery/recovery-cluster.yaml -n goingdark-social

# Monitor recovery progress
kubectl get cluster database-cnpg-recovered -n goingdark-social -w

# Check pod logs for recovery progress
kubectl logs -f database-cnpg-recovered-1 -n goingdark-social -c postgres
```

#### Step 5: Verify Recovery

```bash
# Connect to recovered database and verify data
kubectl exec -it database-cnpg-recovered-1 -n goingdark-social -c postgres -- \
  psql -d mastodon_production -c "SELECT COUNT(*) FROM accounts;"

# Check the recovery target was reached
kubectl exec -it database-cnpg-recovered-1 -n goingdark-social -c postgres -- \
  psql -c "SELECT pg_last_xact_replay_timestamp();"
```

#### Step 6: Switch to Recovered Cluster

```bash
# Delete or rename the old cluster
kubectl delete cluster database-cnpg -n goingdark-social

# Rename the recovered cluster (optional - or update app configs)
kubectl patch cluster database-cnpg-recovered -n goingdark-social \
  --type json \
  --patch '[{"op": "replace", "path": "/metadata/name", "value": "database-cnpg"}]'

# Update application connection strings and scale back up
kubectl scale deployment -n goingdark-social \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  --replicas=1
```

### Scenario 3: Latest Backup Recovery

Use this when you need to **restore to the most recent state** after complete data loss.

#### Step 1: Scale Down Applications

```bash
kubectl scale deployment -n goingdark-social \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  --replicas=0
```

#### Step 2: Apply Recovery Without Target Time

Edit `disaster-recovery/recovery-cluster.yaml` and remove/comment the `recoveryTarget`:

```yaml
spec:
  bootstrap:
    recovery:
      source: backup-source
      # No recoveryTarget = recover to latest available WAL
```

#### Step 3: Apply and Monitor

```bash
kubectl apply -f disaster-recovery/recovery-cluster.yaml -n goingdark-social
kubectl get cluster database-cnpg-recovered -n goingdark-social -w
```

## Verification Procedures

### Pre-Recovery Checks

```bash
# 1. Verify backup accessibility
kubectl exec -it database-cnpg-1 -n goingdark-social -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database \
  database-cnpg

# 2. Check current cluster status
kubectl get cluster -n goingdark-social

# 3. Verify secrets exist
kubectl get secret mastodon-walg-s3 -n goingdark-social
kubectl get secret database-cnpg-app -n goingdark-social
```

### Post-Recovery Validation

```bash
# 1. Check cluster is healthy
kubectl describe cluster <cluster-name> -n goingdark-social

# 2. Verify database connectivity
kubectl exec -it <cluster-name>-1 -n goingdark-social -c postgres -- \
  psql -c "SELECT version();"

# 3. Check data integrity
kubectl exec -it <cluster-name>-1 -n goingdark-social -c postgres -- \
  psql -d mastodon_production -c "
    SELECT 
      (SELECT COUNT(*) FROM accounts) as accounts,
      (SELECT COUNT(*) FROM statuses) as statuses,
      (SELECT COUNT(*) FROM users) as users;
  "

# 4. Verify application connectivity
kubectl run psql-test --rm -it --image=postgres:17 -- \
  psql "postgresql://app:password@<cluster-name>-rw.goingdark-social:5432/mastodon_production" \
  -c "SELECT 1;"
```

## Failback Procedures

After disaster recovery, you may want to return to the original configuration.

### Option 1: Keep Recovered Cluster

1. Update the backup destination path in `database-backup-recovered` ObjectStore
2. Set up new scheduled backups pointing to the recovered cluster
3. Update monitoring and alerting

### Option 2: Migrate Back to Original Cluster Name

```bash
# 1. Take a backup of the recovered cluster
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pre-failback-backup
  namespace: goingdark-social
spec:
  cluster:
    name: database-cnpg-recovered
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: database-backup-recovered
EOF

# 2. Wait for backup to complete
kubectl get backup pre-failback-backup -n goingdark-social -w

# 3. Create new primary cluster from backup
# (Use original cluster name and backup source)
```

## Testing DR Procedures

### Monthly DR Test Checklist

1. **Verify Backups Exist**
   ```bash
   kubectl exec -it database-cnpg-1 -n goingdark-social -c postgres -- \
     barman-cloud-backup-list ...
   ```

2. **Test Recovery to Dev Environment**
   - Apply recovery-cluster.yaml to a dev namespace
   - Verify data integrity
   - Delete test cluster

3. **Test Replica Cluster (Non-Prod)**
   - Deploy replica cluster in test namespace
   - Verify replication lag
   - Test promotion procedure
   - Clean up

4. **Document Results**
   - Record RTO achieved
   - Note any issues
   - Update procedures if needed

### Automated DR Testing (Recommended)

Consider setting up automated DR testing:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dr-test-monthly
  namespace: goingdark-social
spec:
  schedule: "0 2 1 * *"  # First day of each month at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: dr-test
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  # Test backup list accessibility
                  # Create test recovery cluster
                  # Verify data
                  # Clean up
                  # Send notification
          restartPolicy: OnFailure
```

## Troubleshooting

### Common Issues

#### Backup List Returns Empty

```bash
# Check credentials
kubectl get secret mastodon-walg-s3 -n goingdark-social -o yaml

# Verify endpoint URL
kubectl describe objectstore database-backup -n goingdark-social
```

#### Replica Cluster Not Catching Up

```bash
# Check replica logs
kubectl logs database-cnpg-replica-1 -n goingdark-social -c postgres | tail -100

# Verify WAL archive is accessible
kubectl exec -it database-cnpg-replica-1 -n goingdark-social -c postgres -- \
  barman-cloud-wal-restore --help
```

#### Recovery Stuck in "Setting up primary"

```bash
# Check for WAL archive errors
kubectl logs database-cnpg-recovered-1-join -n goingdark-social

# Verify the serverName matches the original cluster
kubectl describe cluster database-cnpg-recovered -n goingdark-social
```

#### "WAL archive check failed" Error

This happens when the destination path already contains data from another cluster:

```bash
# Use a new serverName or destinationPath for recovered clusters
# Edit recovery-cluster.yaml to use unique paths
```

### Getting Help

1. Check CloudNativePG documentation: https://cloudnative-pg.io/documentation/
2. Review operator logs: `kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg`
3. Check PostgreSQL logs: `kubectl logs <cluster>-1 -n goingdark-social -c postgres`

## References

- [CloudNativePG Backup and Recovery](https://cloudnative-pg.io/documentation/current/backup_recovery/)
- [CloudNativePG Replica Clusters](https://cloudnative-pg.io/documentation/current/replica_cluster/)
- [Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/)
- [PostgreSQL PITR Documentation](https://www.postgresql.org/docs/current/continuous-archiving.html)
