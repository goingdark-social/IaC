# Zalando to CloudNative-PG Migration Guide: Replica-Based Approach

## Overview

This guide documents the **replica-based migration strategy** using physical replication (pg_basebackup + streaming replication) to migrate from Zalando PostgreSQL to CloudNative-PG with minimal downtime.

### Downtime Comparison

| Method | Downtime | Complexity | Risk |
|--------|----------|------------|------|
| pg_dump/restore (current) | 5-15 minutes | Low | Low |
| **Physical replication (this guide)** | **30s - 2 minutes** | Medium | Low-Medium |
| Logical replication | 10-30 seconds | High | Medium |

## Architecture Overview

### Migration Flow

```
┌─────────────────┐         ┌──────────────────┐
│ Zalando Primary │────────▶│ CNPG Replica     │
│ (mastodon-pg)   │ Stream  │ (database)       │
│                 │ Repl    │ (READ-ONLY)      │
└─────────────────┘         └──────────────────┘
        │                            │
        │ Apps connected             │ Apps NOT connected
        │ (READ-WRITE)               │ (preparation phase)
        ▼                            ▼

            [CUTOVER MOMENT]
         Applications scaled down
         Wait for replication sync
         Promote CNPG to primary
         Update app configuration
         Scale applications up

┌─────────────────┐         ┌──────────────────┐
│ Zalando         │         │ CNPG Primary ◀───┤
│ (DEPRECATED)    │         │ (database)       │
│                 │         │ (READ-WRITE)     │
└─────────────────┘         └──────────────────┘
        │                            ▲
        │ No connections             │ Apps connected
        ▼                            │

     [Cleanup after 7+ days]
```

## How Physical Replication Works

### Technical Details

1. **Initial Sync**: CloudNative-PG uses `pg_basebackup` to create a binary copy of Zalando's data
2. **Streaming Replication**: CNPG continuously receives WAL (Write-Ahead Log) records from Zalando
3. **Replica Mode**: CNPG operates in continuous recovery mode, applying WAL changes in real-time
4. **Promotion**: During cutover, CNPG stops replication and becomes a standalone primary cluster

### Key Benefits

- ✅ **Exact binary copy** - No schema translation or data type issues
- ✅ **Continuous replication** - CNPG stays synchronized until cutover
- ✅ **No Zalando restart** - Only requires adding a replication user
- ✅ **Minimal downtime** - 30 seconds to 2 minutes (vs 5-15 minutes)
- ✅ **Easy rollback** - Switch back to Zalando if issues occur
- ✅ **All PostgreSQL features** - Large objects, system catalogs, everything replicates

## Prerequisites

### Version Compatibility
- ✅ **PostgreSQL versions must match exactly**: Both Zalando and CNPG are running PostgreSQL 17

### Resource Requirements
- **Storage**: CNPG needs at least as much storage as Zalando (currently 40Gi configured)
- **Network**: Bidirectional connectivity between Zalando and CNPG pods
- **CPU/Memory**: CNPG should match or exceed Zalando's resources during replication

### Access Requirements
- Cluster admin access to create secrets and jobs
- Ability to scale applications to zero
- Access to Zalando TLS certificates
- CNPG operator installed and functional

## Phase 1: Preparation (No Downtime)

### Step 1.1: Create Streaming Replica User in Zalando

Apply the preparation job to create the `streaming_replica` user:

```bash
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/replica-migration-prepare-zalando.yaml

# Run the job
kubectl create job replica-prep-$(date +%Y%m%d-%H%M) \
  --from=job/replica-migration-prepare-zalando -n mastodon

# Monitor progress
kubectl logs -f job/replica-prep-$(date +%Y%m%d-%H%M) -n mastodon
```

**What this does:**
- Creates `streaming_replica` user with `REPLICATION` and `LOGIN` privileges
- Sets a secure password (stored in Kubernetes secret)
- Configures pg_hba.conf to allow replication connections (via Zalando operator)

**Expected output:**
```
✓ Creating streaming_replica user...
✓ Password stored in secret: zalando-streaming-replica
✓ User has REPLICATION and LOGIN privileges
✓ Ready for replication setup
```

**Success criteria:**
- Job completes successfully
- Secret `zalando-streaming-replica` exists
- Can connect to Zalando with streaming_replica user

**Troubleshooting:**
```bash
# Verify user was created
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "\du streaming_replica"

# Should show: streaming_replica | Replication | {}
```

### Step 1.2: Extract Zalando TLS Certificates

Extract TLS certificates from Zalando for CNPG to use during replication:

```bash
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/replica-migration-extract-certs.yaml

# Run the extraction job
kubectl create job extract-certs-$(date +%Y%m%d-%H%M) \
  --from=job/replica-migration-extract-certs -n mastodon

# Monitor progress
kubectl logs -f job/extract-certs-$(date +%Y%m%d-%H%M) -n mastodon
```

**What this does:**
- Extracts client certificate from `mastodon-postgresql-server` secret
- Extracts CA certificate from `mastodon-postgresql-ca` secret
- Creates CNPG-compatible secrets for replication authentication

**Expected output:**
```
✓ Extracting Zalando TLS certificates...
✓ Created secret: zalando-replication-tls (client cert + key)
✓ Created secret: zalando-replication-ca (CA certificate)
✓ Certificates ready for CNPG replication
```

**Success criteria:**
- Secrets `zalando-replication-tls` and `zalando-replication-ca` exist
- Certificates are valid and not expired

**Troubleshooting:**
```bash
# Verify secrets exist
kubectl get secret zalando-replication-tls zalando-replication-ca -n mastodon

# Check certificate expiry
kubectl get secret mastodon-postgresql-ca -n mastodon -o jsonpath='{.data.ca\.crt}' | \
  base64 -d | openssl x509 -noout -enddate
```

### Step 1.3: Deploy CNPG as Replica

Apply the replica-configured CNPG cluster:

```bash
# Apply the replica-enabled CNPG cluster manifest
kubectl apply -f kubernetes/apps/platform/mastodon/resources/workloads/database-cluster-replica.yaml

# Monitor the initial sync (will take 10-30 minutes depending on database size)
kubectl get cluster database -n mastodon -w
```

**What this does:**
- Deploys CNPG cluster with `bootstrap.pg_basebackup` configuration
- CNPG connects to Zalando using streaming_replica user
- Performs initial pg_basebackup to copy all data
- Starts streaming replication from Zalando
- CNPG operates in read-only replica mode

**Expected output:**
```
# Initial state
database   1           0s       Initializing primary      Cluster in healthy state

# During pg_basebackup
database   1          2m       Bootstrapping            Streaming backup from source

# After initial sync completes
database   2          15m      Cluster in healthy state  Continuous recovery in progress

# Final state (both instances running)
database   2          20m      Cluster in healthy state  Streaming from zalando-cluster
```

**Success criteria:**
- CNPG cluster shows "Cluster in healthy state"
- Both instances are running
- Logs show "streaming replication" is active
- Replication lag is minimal (< 1 second)

**Troubleshooting:**
```bash
# Check cluster status
kubectl cnpg status database -n mastodon

# Check logs for replication status
kubectl logs -l cnpg.io/cluster=database -n mastodon | grep -i replication

# Check for errors
kubectl get events -n mastodon --field-selector involvedObject.name=database

# If pg_basebackup fails, check connectivity
kubectl exec -it database-1 -n mastodon -- \
  pg_isready -h mastodon-postgresql-rw.mastodon.svc -p 5432
```

### Step 1.4: Validate Replication Status

Check that streaming replication is working correctly:

```bash
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/replica-migration-validate-replication.yaml

# Run validation
kubectl create job validate-replication-$(date +%Y%m%d-%H%M) \
  --from=job/replica-migration-validate-replication -n mastodon

# Monitor validation
kubectl logs -f job/validate-replication-$(date +%Y%m%d-%H%M) -n mastodon
```

**What this checks:**
- Replication lag (should be < 1 second)
- Row counts match between Zalando and CNPG
- LSN (Log Sequence Number) progressing
- No replication errors

**Expected output:**
```
✓ Checking replication status...
  Zalando LSN: 0/5A2E4F8
  CNPG LSN:    0/5A2E4F8
  Lag:         0 seconds

✓ Validating data consistency...
  accounts:    123,456 rows (Zalando) ✓ matches (CNPG)
  statuses:    1,234,567 rows (Zalando) ✓ matches (CNPG)
  users:       45,678 rows (Zalando) ✓ matches (CNPG)

✓ Replication is healthy and ready for cutover
```

**Success criteria:**
- Replication lag < 5 seconds
- All key table row counts match
- No replication errors in logs
- LSN is progressing (not stuck)

**Troubleshooting:**
```bash
# Check replication lag on CNPG
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"

# Check replication status on Zalando
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Should show streaming_replica connected
```

### Step 1.5: Pre-Cutover Checklist

Before proceeding to cutover, ensure all conditions are met:

- [ ] Streaming replication is active and healthy
- [ ] Replication lag is consistently < 5 seconds
- [ ] All validation checks pass
- [ ] CNPG cluster has 2 healthy instances
- [ ] Zalando cluster is healthy and stable
- [ ] Applications are running normally
- [ ] Backup taken of Zalando (safety measure)
- [ ] Maintenance window scheduled and communicated
- [ ] Rollback plan documented and tested
- [ ] Team members available for monitoring

## Phase 2: Cutover (30 seconds - 2 minutes Downtime)

### ⚠️ CRITICAL: This phase causes downtime

**Timing Recommendations:**
- **Best time**: Low-traffic period (2-6 AM UTC)
- **Avoid**: High activity periods, during scheduled backups
- **Duration**: Reserve 30-minute window (actual downtime: 30s-2min)

### Step 2.1: Execute Cutover

Run the automated cutover orchestration job:

```bash
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/replica-migration-cutover.yaml

# IMPORTANT: Review the job manifest before running
kubectl get job replica-migration-cutover -n mastodon -o yaml | less

# Execute cutover (this will scale down applications)
kubectl create job cutover-$(date +%Y%m%d-%H%M) \
  --from=job/replica-migration-cutover -n mastodon

# Monitor cutover progress (stay connected!)
kubectl logs -f job/cutover-$(date +%Y%m%d-%H%M) -n mastodon
```

**What this does:**
1. **Records current replica counts** - Saves current scaling for rollback
2. **Scales down all applications** - mastodon-web, sidekiq-*, streaming (downtime begins)
3. **Waits for replication to catch up** - Ensures CNPG has all data
4. **Promotes CNPG to primary** - Breaks replication, makes CNPG writable
5. **Waits for promotion to complete** - CNPG becomes independent primary
6. **Updates application configuration** - Changes DB_HOST to CNPG endpoints
7. **Scales up applications** - Restores original replica counts (downtime ends)
8. **Performs basic validation** - Checks connectivity and data access

**Expected timeline:**
```
00:00 - Recording replica counts
00:05 - Scaling down applications... (DOWNTIME BEGINS)
00:45 - All applications scaled down
00:50 - Waiting for replication to catch up...
00:55 - Replication lag: 0 seconds
01:00 - Promoting CNPG to primary...
01:15 - CNPG promoted successfully
01:20 - Updating application configuration...
01:25 - Scaling up applications...
01:45 - mastodon-web: 2/2 replicas ready
01:50 - mastodon-sidekiq-*: all replicas ready
01:55 - mastodon-streaming: 1/1 replicas ready
02:00 - Basic validation passed (DOWNTIME ENDS)
02:05 - Cutover completed successfully
```

**Critical monitoring points:**

1. **Application scale down** (first 45 seconds)
```bash
# Watch applications scale down
watch -n 1 'kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"'
```

2. **Replication catchup** (5-10 seconds)
```bash
# Should see "Replication lag: 0 seconds" quickly
```

3. **CNPG promotion** (10-15 seconds)
```bash
# CNPG becomes primary, exits recovery mode
kubectl get cluster database -n mastodon -w
```

4. **Application scale up** (30-60 seconds)
```bash
# Watch applications come back online
watch -n 1 'kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"'
```

**Success criteria:**
- Job completes without errors
- All applications scaled back up
- No connection errors in application logs
- Can perform write operations on CNPG
- Mastodon UI accessible and functional

**Troubleshooting:**

If cutover fails at any stage:

```bash
# EMERGENCY ROLLBACK: Stop the job
kubectl delete job cutover-$(date +%Y%m%d-%H%M) -n mastodon

# Manually restore application scaling (if job didn't complete)
# The job saves replica counts to ConfigMap: cutover-replica-counts
kubectl get configmap cutover-replica-counts -n mastodon -o yaml

# Manual scale up using saved counts
kubectl scale deployment mastodon-web --replicas=<saved-count> -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=<saved-count> -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=<saved-count> -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=<saved-count> -n mastodon
kubectl scale deployment mastodon-streaming --replicas=<saved-count> -n mastodon

# Verify Zalando is still accessible
kubectl exec -it $(kubectl get pods -n mastodon -l app=mastodon-web -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql $DATABASE_URL -c "SELECT COUNT(*) FROM accounts;"
```

If CNPG promotion fails:

```bash
# Check CNPG cluster status
kubectl cnpg status database -n mastodon

# Check for errors
kubectl logs -l cnpg.io/cluster=database -n mastodon

# Manual promotion attempt
kubectl cnpg promote database -n mastodon

# If promotion won't work, applications will automatically reconnect to Zalando
# No data loss - replication was still active until promotion attempt
```

### Step 2.2: Post-Cutover Immediate Validation

Immediately after cutover completes, verify the migration was successful:

```bash
# Test write operations on CNPG
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -d mastodon -c "CREATE TABLE migration_test (id serial, created_at timestamp default now());"

kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -d mastodon -c "INSERT INTO migration_test DEFAULT VALUES; SELECT * FROM migration_test;"

kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -d mastodon -c "DROP TABLE migration_test;"

# Should complete without errors

# Check application logs for database errors
kubectl logs -f deployment/mastodon-web -n mastodon | grep -i "error\|exception"
kubectl logs -f deployment/mastodon-sidekiq-default -n mastodon | grep -i "error\|exception"

# Test Mastodon functionality
# - Open Mastodon UI
# - Try to post a status
# - Check home timeline loads
# - Verify notifications work

# Check database connections
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT application_name, count(*) FROM pg_stat_activity WHERE state = 'active' GROUP BY application_name;"
```

## Phase 3: Monitoring & Validation (No Downtime)

### Step 3.1: 24-Hour Monitoring Checklist

Monitor the following metrics for 24-48 hours after cutover:

**Database Health:**
```bash
# Check CNPG cluster health
kubectl cnpg status database -n mastodon

# Monitor connection counts
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"

# Check for long-running queries
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT pid, now() - query_start AS duration, query FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '5 minutes';"
```

**Application Health:**
```bash
# Check pod restart counts (should not increase)
kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"

# Monitor application logs for errors
kubectl logs -f deployment/mastodon-web -n mastodon --tail=100
kubectl logs -f deployment/mastodon-sidekiq-default -n mastodon --tail=100

# Check HPA metrics (autoscaling should work normally)
kubectl get hpa -n mastodon
```

**Backup Health:**
```bash
# Verify CNPG backups are running
kubectl get backup -n mastodon

# Check last backup status
kubectl get backup -n mastodon -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.startedAt}{"\n"}{end}'

# Should show successful backups to S3
```

**Performance Metrics:**
- Query response times (should be similar or better than Zalando)
- Connection pool utilization (should be stable)
- CPU/Memory usage (should be within expected range)
- Disk I/O (should not show unusual spikes)

### Step 3.2: Comprehensive Validation

After 24 hours of stability, run comprehensive validation:

```bash
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/cnpg-validation-job.yaml

# Run full validation suite
kubectl create job cnpg-validation-post-migration-$(date +%Y%m%d) \
  --from=job/cnpg-validation-job -n mastodon

# Monitor validation
kubectl logs -f job/cnpg-validation-post-migration-$(date +%Y%m%d) -n mastodon
```

**What this validates:**
- Schema integrity (all tables, indexes, constraints present)
- Data consistency (row counts match expected values)
- Performance benchmarks (query times within acceptable range)
- SSL configuration (certificates valid, connections encrypted)
- Pooler functionality (read-write and read-only endpoints work)
- Extension availability (all required PostgreSQL extensions present)

## Phase 4: Cleanup (After 7+ Days Stability)

### Step 4.1: Pre-Cleanup Validation

Before removing Zalando, ensure CNPG has been stable for at least 7 days:

**Stability checklist:**
- [ ] No database-related incidents in last 7 days
- [ ] CNPG backups running successfully
- [ ] All applications connecting to CNPG
- [ ] No connection errors in logs
- [ ] Performance metrics stable
- [ ] No user-reported issues
- [ ] Team consensus to proceed with cleanup

### Step 4.2: Disable Zalando Replication

Zalando is no longer receiving connections, but it's still consuming resources:

```bash
# Verify NO applications are connecting to Zalando
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "SELECT application_name, count(*) FROM pg_stat_activity WHERE application_name != '' GROUP BY application_name;"

# Should show ONLY: streaming_replica | 1 (from CNPG)
# If you see mastodon-web, sidekiq, etc. - DO NOT PROCEED

# Scale down Zalando pooler (saves resources, keeps Zalando available)
kubectl scale deployment mastodon-postgresql-pooler --replicas=0 -n mastodon
kubectl scale deployment mastodon-postgresql-pooler-repl --replicas=0 -n mastodon
```

### Step 4.3: Remove Zalando Cluster (Optional)

⚠️ **WARNING: This step is irreversible. Ensure CNPG is stable and backed up before proceeding.**

```bash
# Create final backup of Zalando (safety measure)
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/zalando-backup-job.yaml
kubectl create job zalando-final-backup-$(date +%Y%m%d) --from=job/zalando-backup-job -n mastodon

# Wait for backup to complete
kubectl logs -f job/zalando-final-backup-$(date +%Y%m%d) -n mastodon

# Delete Zalando PostgreSQL cluster
kubectl delete postgresql mastodon-postgresql -n mastodon

# This will:
# - Stop all Zalando pods
# - Delete Zalando PVCs (if configured)
# - Remove Zalando connection pooler
# - Clean up Zalando secrets (optional)

# Remove Zalando-related secrets (optional, keep for 30 days as backup)
# kubectl delete secret mastodon-postgresql-server -n mastodon
# kubectl delete secret mastodon-postgresql-ca -n mastodon
# kubectl delete secret zalando-streaming-replica -n mastodon
```

### Step 4.4: Update Repository Documentation

After successful migration:

1. **Update CLAUDE.md**:
   - Remove references to Zalando postgres-operator
   - Update PostgreSQL operator section to only mention CloudNative-PG
   - Update connection strings in examples

2. **Archive migration documentation**:
   - Move MIGRATION_GUIDE.md to `docs/archive/`
   - Move REPLICA_MIGRATION_GUIDE.md (this file) to `docs/`

3. **Update application documentation**:
   - Update connection string examples
   - Document CNPG-specific features (pooler, backup/restore)

4. **Create post-migration runbook**:
   - Document CNPG backup/restore procedures
   - Document CNPG troubleshooting steps
   - Document CNPG scaling procedures

## Rollback Procedures

### Emergency Rollback During Preparation (Phase 1)

If issues are discovered during preparation (before cutover):

```bash
# Simply delete the CNPG replica cluster
kubectl delete cluster database -n mastodon

# This will:
# - Stop CNPG replication
# - Remove CNPG pods
# - Optionally remove CNPG PVCs

# Applications continue using Zalando normally - zero impact
```

### Emergency Rollback During Cutover (Phase 2)

If issues occur during cutover:

```bash
# 1. Stop the cutover job immediately
kubectl delete job cutover-$(date +%Y%m%d-%H%M) -n mastodon

# 2. Check application status
kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"

# 3. If applications are scaled down, restore them manually
# Get saved replica counts from ConfigMap
kubectl get configmap cutover-replica-counts -n mastodon -o yaml

# Restore scaling (using saved counts from ConfigMap)
kubectl scale deployment mastodon-web --replicas=<count> -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=<count> -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=<count> -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=<count> -n mastodon
kubectl scale deployment mastodon-streaming --replicas=<count> -n mastodon

# 4. Verify applications are connecting to Zalando
kubectl logs -f deployment/mastodon-web -n mastodon | grep -i "database"

# 5. If configuration was updated to CNPG, revert it
# Edit mastodon-database.env back to Zalando endpoints
# DB_HOST=mastodon-postgresql-pooler (instead of database-pooler-rw)

# 6. Test application functionality
```

**What gets rolled back:**
- ✅ Application connections (back to Zalando)
- ✅ Application configuration (DB_HOST)
- ✅ Application scaling (restored to original)

**What does NOT get rolled back:**
- ⚠️ CNPG promotion (if it succeeded) - CNPG becomes independent
- ⚠️ Any writes that happened to CNPG (if promotion succeeded)

**If CNPG was promoted:**
- CNPG is now an independent primary cluster
- Zalando and CNPG have diverged - they are no longer synchronized
- Data written to CNPG during cutover is NOT in Zalando
- **Recommendation**: Do not use Zalando if CNPG was promoted - data loss risk

### Post-Cutover Rollback (Within 48 Hours)

If critical issues are discovered after successful cutover:

⚠️ **WARNING: This scenario is complex and may result in data loss**

**Before rolling back, consider:**
1. **Data divergence**: Zalando does not have data written to CNPG since cutover
2. **Potential data loss**: Any activity since cutover will be lost
3. **User impact**: Downtime required to switch back
4. **Alternative**: Fix issues in CNPG instead of rolling back

**If you must rollback:**

```bash
# 1. Scale down applications (DOWNTIME BEGINS)
kubectl scale deployment mastodon-web --replicas=0 -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=0 -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=0 -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=0 -n mastodon
kubectl scale deployment mastodon-streaming --replicas=0 -n mastodon

# 2. Take final backup of CNPG (to preserve post-cutover data)
kubectl cnpg backup database -n mastodon --backup-name emergency-pre-rollback-$(date +%Y%m%d)

# 3. Optionally: Try to sync data from CNPG back to Zalando
# WARNING: This is complex and error-prone
# Consider using pg_dump from CNPG -> pg_restore to Zalando
# Only do this if you understand the risks

# 4. Update application configuration back to Zalando
# Edit mastodon-database.env
# DB_HOST=mastodon-postgresql-pooler
# REPLICA_DB_HOST=mastodon-postgresql-repl

# 5. Apply configuration changes
kubectl apply -k kubernetes/apps/platform/mastodon/

# 6. Scale up applications (DOWNTIME ENDS)
kubectl scale deployment mastodon-web --replicas=<original> -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=<original> -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=<original> -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=<original> -n mastodon
kubectl scale deployment mastodon-streaming --replicas=<original> -n mastodon

# 7. Verify applications connect to Zalando
kubectl logs -f deployment/mastodon-web -n mastodon | grep -i "postgres"

# 8. Test application functionality
# - Verify timeline loads
# - Check notifications
# - Ensure posts work

# 9. Investigate CNPG issues
# - Keep CNPG cluster running for investigation
# - Identify root cause before attempting migration again
```

**Data loss scenarios:**
- Any posts, favorites, follows since cutover will be lost
- User notifications generated after cutover will be missing
- Federated activities may be out of sync with other instances

**Recommendation**: Only rollback if CNPG is completely broken and unfixable. Otherwise, fix issues in CNPG.

## Troubleshooting Common Issues

### Issue 1: pg_basebackup Fails During Initial Sync

**Symptoms:**
- CNPG cluster stuck in "Bootstrapping" state
- Logs show connection errors or authentication failures

**Diagnosis:**
```bash
# Check CNPG cluster status
kubectl describe cluster database -n mastodon

# Check logs
kubectl logs -l cnpg.io/cluster=database -n mastodon | grep -i "error\|basebackup"

# Common errors:
# - "connection refused" - network issue
# - "authentication failed" - credentials/TLS issue
# - "permission denied" - replication user lacks privileges
```

**Resolution:**

1. **Connection refused:**
```bash
# Test connectivity from CNPG pod to Zalando
kubectl exec -it database-1 -n mastodon -- \
  pg_isready -h mastodon-postgresql-rw.mastodon.svc -p 5432

# If fails, check Zalando is running
kubectl get pods -n mastodon -l app=postgresql
```

2. **Authentication failed:**
```bash
# Verify streaming_replica user exists
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "\du streaming_replica"

# Verify secret has correct password
kubectl get secret zalando-streaming-replica -n mastodon -o jsonpath='{.data.password}' | base64 -d

# Test authentication manually
kubectl exec -it database-1 -n mastodon -- \
  psql "host=mastodon-postgresql-rw.mastodon.svc port=5432 user=streaming_replica sslmode=verify-full" -c "SELECT version();"
```

3. **TLS certificate issues:**
```bash
# Verify secrets exist
kubectl get secret zalando-replication-tls zalando-replication-ca -n mastodon

# Check certificate is valid
kubectl get secret mastodon-postgresql-ca -n mastodon -o jsonpath='{.data.ca\.crt}' | \
  base64 -d | openssl x509 -noout -dates

# Re-run certificate extraction if needed
kubectl delete job extract-certs-* -n mastodon
kubectl create job extract-certs-retry --from=job/replica-migration-extract-certs -n mastodon
```

4. **Replication privileges:**
```bash
# Verify user has REPLICATION role
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'streaming_replica';"

# Should show: streaming_replica | t

# If false, grant replication
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "ALTER USER streaming_replica REPLICATION;"
```

### Issue 2: High Replication Lag

**Symptoms:**
- Replication lag > 5 seconds consistently
- LSN not progressing on CNPG
- Validation job reports data mismatch

**Diagnosis:**
```bash
# Check replication lag
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"

# Check if WAL is being received
kubectl logs -l cnpg.io/cluster=database -n mastodon | grep -i "wal\|replication"

# Check Zalando replication slot
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "SELECT * FROM pg_replication_slots WHERE active = true;"
```

**Common causes:**

1. **Network latency:**
```bash
# Test network performance
kubectl exec -it database-1 -n mastodon -- \
  ping -c 10 mastodon-postgresql-rw.mastodon.svc

# Should show low latency (< 10ms)
```

2. **Zalando under heavy load:**
```bash
# Check Zalando resource usage
kubectl top pods -n mastodon | grep postgresql

# Check active connections
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# If > 200, consider scaling down non-essential workloads temporarily
```

3. **CNPG applying WAL slowly (resource-constrained):**
```bash
# Check CNPG resource usage
kubectl top pods -n mastodon | grep database

# If CPU/memory limits hit, consider temporarily increasing resources
kubectl edit cluster database -n mastodon
# Increase resources.limits.memory from 2Gi to 4Gi temporarily
```

**Resolution:**
- Wait for lag to decrease (may take 10-30 minutes)
- Reduce load on Zalando during initial sync
- Increase CNPG resources temporarily
- If lag persists > 30 minutes, investigate deeper (disk I/O, network)

### Issue 3: Cutover Fails During Promotion

**Symptoms:**
- Cutover job shows "CNPG promotion failed"
- CNPG cluster stuck in replica mode
- Cannot write to CNPG

**Diagnosis:**
```bash
# Check CNPG cluster status
kubectl cnpg status database -n mastodon

# Check for promotion errors
kubectl logs -l cnpg.io/cluster=database -n mastodon | grep -i "promot\|primary"

# Check if still in recovery mode
kubectl exec -it database-1 -n mastodon -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should be 'f' (false) after promotion, 't' (true) if still replica
```

**Resolution:**

1. **Manual promotion:**
```bash
# Try manual promotion via kubectl plugin
kubectl cnpg promote database -n mastodon

# Wait 30 seconds, then check status
kubectl cnpg status database -n mastodon
```

2. **If manual promotion fails:**
```bash
# Check for replication conflicts
kubectl logs -l cnpg.io/cluster=database -n mastodon | grep -i "conflict\|error"

# Check if promote command was received
kubectl get cluster database -n mastodon -o yaml | grep -A 10 "promote"

# Force promotion by deleting standby.signal file
kubectl exec -it database-1 -n mastodon -- \
  rm -f /var/lib/postgresql/data/standby.signal

# Restart PostgreSQL
kubectl delete pod database-1 -n mastodon
```

3. **If still fails, rollback:**
```bash
# Stop cutover job
kubectl delete job cutover-* -n mastodon

# Restore applications to Zalando (see Rollback section)
```

### Issue 4: Applications Can't Connect to CNPG After Cutover

**Symptoms:**
- Application logs show connection refused or timeout errors
- "could not connect to server" messages
- Pods crash-looping

**Diagnosis:**
```bash
# Check pooler status
kubectl get pooler database-pooler-rw -n mastodon
kubectl describe pooler database-pooler-rw -n mastodon

# Check if pooler pods are running
kubectl get pods -n mastodon | grep pooler

# Test connectivity from application pod
kubectl exec -it $(kubectl get pods -n mastodon -l app=mastodon-web -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  pg_isready -h database-pooler-rw -p 5432
```

**Common causes:**

1. **Pooler not running:**
```bash
# Check pooler logs
kubectl logs -l app=database-pooler-rw -n mastodon

# Restart pooler if needed
kubectl rollout restart deployment database-pooler-rw -n mastodon
```

2. **Configuration not updated:**
```bash
# Check environment variables in application
kubectl exec -it $(kubectl get pods -n mastodon -l app=mastodon-web -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  env | grep DB_HOST

# Should show: DB_HOST=database-pooler-rw
# If shows mastodon-postgresql-pooler, configuration wasn't updated

# Update and restart applications
kubectl apply -k kubernetes/apps/platform/mastodon/
kubectl rollout restart deployment mastodon-web -n mastodon
```

3. **NetworkPolicy blocking connections:**
```bash
# Check NetworkPolicy for database
kubectl get networkpolicy -n mastodon
kubectl describe networkpolicy database -n mastodon

# Ensure policy allows ingress from application namespaces
```

## Performance Optimization

### Tuning Replication Performance

For large databases (> 20GB), optimize replication during preparation:

```yaml
# Temporarily increase CNPG resources during initial sync
spec:
  resources:
    requests:
      cpu: "2"
      memory: "4Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
```

### Reducing Cutover Downtime

To minimize downtime to under 1 minute:

1. **Ensure replication lag is < 1 second** before starting cutover
2. **Pre-scale applications down** during maintenance window start
3. **Use fast promotion** (kubectl cnpg promote is faster than automated orchestration)
4. **Pre-warm application configuration** (update configs but don't restart until after promotion)

### Monitoring During Migration

Set up alerts for:

```yaml
# Replication lag > 10 seconds
alert: HighReplicationLag
expr: |
  cnpg_pg_replication_lag_seconds > 10

# Replication stopped
alert: ReplicationStopped
expr: |
  cnpg_pg_replication_is_in_recovery == 0 AND cnpg_pg_replication_lag_seconds > 60

# Cutover taking too long
alert: CutoverTimeout
expr: |
  time() - kube_job_status_start_time{job="cutover-*"} > 300
```

## Success Criteria

### Migration Success (Cutover Completion)

- ✅ Cutover job completed without errors
- ✅ CNPG promoted to primary (pg_is_in_recovery = false)
- ✅ All applications scaled back up
- ✅ No connection errors in application logs
- ✅ Can perform write operations on CNPG
- ✅ Mastodon UI accessible and functional
- ✅ Basic data validation passed (row counts match)

### Long-term Success (After 7 Days)

- ✅ Zero database-related incidents
- ✅ CNPG backups running successfully
- ✅ Performance metrics stable or improved
- ✅ No replication-related errors in logs
- ✅ Resource usage within expected range
- ✅ No user-reported data issues
- ✅ Team comfortable with CNPG operations

## Lessons Learned (Post-Migration)

### Document the Following After Migration:

1. **Actual downtime experienced** vs estimated
2. **Issues encountered** and how they were resolved
3. **Performance changes** (better/worse/same)
4. **Resource usage changes** (CPU, memory, storage)
5. **Backup/restore procedures** specific to CNPG
6. **Operational differences** between Zalando and CNPG

### Update Team Documentation:

- [ ] Runbooks updated with CNPG procedures
- [ ] Monitoring dashboards updated for CNPG metrics
- [ ] Alert rules adjusted for CNPG specifics
- [ ] Incident response playbooks include CNPG scenarios
- [ ] Disaster recovery procedures updated

## Additional Resources

### CloudNative-PG Documentation
- Official docs: https://cloudnative-pg.io/documentation/
- Replication guide: https://cloudnative-pg.io/documentation/current/replication/
- Bootstrap methods: https://cloudnative-pg.io/documentation/current/bootstrap/
- Replica clusters: https://cloudnative-pg.io/documentation/current/replica_cluster/

### Migration References
- IBM Instana guide: https://www.ibm.com/docs/en/instana-observability/current?topic=postgres-migrating-data-from-zalando-cnpg
- Near-zero downtime migration: https://www.gabrielebartolini.it/articles/2024/03/cloudnativepg-recipe-5-how-to-migrate-your-postgresql-database-in-kubernetes-with-~0-downtime-from-anywhere/

### Troubleshooting Resources
- CloudNative-PG FAQ: https://cloudnative-pg.io/documentation/current/faq/
- PostgreSQL replication docs: https://www.postgresql.org/docs/17/warm-standby.html
- Kubernetes PostgreSQL operators comparison: https://blog.palark.com/cloudnativepg-and-other-kubernetes-operators-for-postgresql/

## Conclusion

This replica-based migration strategy provides a safe, tested path from Zalando PostgreSQL to CloudNative-PG with minimal downtime (30 seconds to 2 minutes vs 5-15 minutes with pg_dump approach). The key advantages are:

1. **Continuous replication** ensures CNPG stays synchronized until cutover
2. **Minimal Zalando changes** (only adding replication user, no restart)
3. **Easy rollback** during preparation phase with zero risk
4. **Battle-tested approach** used successfully in production environments
5. **Full data fidelity** via binary replication

The migration is designed to be executed during a maintenance window with comprehensive validation at each step. The cutover process is automated but includes manual checkpoints for safety. Rollback procedures are documented for each phase to minimize risk.

After successful migration, CloudNative-PG provides a modern, cloud-native PostgreSQL platform with improved backup/restore capabilities, better Kubernetes integration, and active development/support.
