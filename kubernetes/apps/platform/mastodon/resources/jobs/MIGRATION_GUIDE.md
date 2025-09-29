# Zalando PostgreSQL to CloudNativePG Migration Guide

## Overview

This guide provides step-by-step instructions for migrating from Zalando PostgreSQL to CloudNativePG (CNPG) with minimal downtime and maximum safety. The migration process is designed to be reversible and includes comprehensive validation at each step.

## Architecture Overview

### Current State (Zalando PostgreSQL)
- **Primary**: `mastodon-postgresql-pooler` (read-write)
- **Replica**: `mastodon-postgresql-repl` (read-only)
- **Pooler**: `mastodon-postgresql-pooler-repl` (read-only pooler)

### Target State (CloudNativePG)
- **Primary**: `database-pooler-rw` (read-write)
- **Replica**: `database-pooler-ro` (read-only)
- **Direct Access**: `database-rw`, `database-ro`, `database-r`

## Migration Strategy

### Zero-Downtime Approach
The migration minimizes downtime by:
1. **Pre-migration testing** - Validate both systems without affecting production
2. **Controlled application scaling** - Brief downtime only during data transfer
3. **Instant rollback capability** - Keep Zalando running as backup
4. **Progressive validation** - Multiple checkpoints to ensure success

### Downtime Estimate
- **Total downtime**: 5-15 minutes (depending on database size)
- **Backup creation**: ~2-5 minutes (runs while apps are scaled down)
- **Data restoration**: ~3-10 minutes (depends on data volume)
- **Validation**: ~30 seconds (basic checks only during downtime)

## Prerequisites

### 1. Infrastructure Requirements
```bash
# Verify both database systems are running
kubectl get pods -n mastodon | grep -E "(database|postgresql)"

# Check resource availability (need ~20GB temp storage)
kubectl describe nodes | grep -A 5 "Allocated resources"
```

### 2. Access Requirements
- Cluster admin access (for scaling applications)
- Database access to both Zalando and CNPG
- S3 access for backups (already configured)

### 3. Timing Considerations
- **Best time**: Low-traffic periods (early morning UTC)
- **Avoid**: High activity periods, during backups, maintenance windows
- **Duration**: Reserve 2-4 hour maintenance window

## Step-by-Step Migration Process

### Phase 1: Pre-Migration Validation (No Downtime)

#### Step 1.1: Test Zalando Backup System
```bash
# Enable the backup job
cd kubernetes/apps/platform/mastodon/resources/jobs
sed -i 's/# - zalando-backup-job.yaml/- zalando-backup-job.yaml/' kustomization.yaml

# Apply and run the backup test
kubectl apply -k .
kubectl create job zalando-backup-test --from=job/zalando-backup-job -n mastodon

# Monitor the backup
kubectl logs -f job/zalando-backup-test -n mastodon
```

**Expected Duration**: 5-10 minutes
**Success Criteria**:
- Backup completes without errors
- Key Mastodon tables (accounts, statuses, users) are present
- Backup file size is reasonable (>100MB for active instance)

#### Step 1.2: Test CNPG Preparation
```bash
# Enable the preparation job
sed -i 's/# - cnpg-prepare-job.yaml/- cnpg-prepare-job.yaml/' kustomization.yaml

# Apply and run the preparation test
kubectl apply -k .
kubectl create job cnpg-prepare-test --from=job/cnpg-prepare-job -n mastodon

# Monitor the preparation
kubectl logs -f job/cnpg-prepare-test -n mastodon
```

**Expected Duration**: 2-5 minutes
**Success Criteria**:
- CNPG read-write and read-only endpoints accessible
- SSL connections working
- Database is empty or contains only test data
- Required PostgreSQL extensions available

#### Step 1.3: Verify Current Application Health
```bash
# Check application status
kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"

# Check current database connections
kubectl exec -it $(kubectl get pods -n mastodon -l app=mastodon-web -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql $DATABASE_URL -c "SELECT count(*) as active_connections FROM pg_stat_activity WHERE state = 'active';"

# Record current replica counts for rollback
kubectl get deployment mastodon-web -n mastodon -o jsonpath='{.spec.replicas}' > /tmp/mastodon-web-replicas
kubectl get deployment mastodon-sidekiq-default -n mastodon -o jsonpath='{.spec.replicas}' > /tmp/mastodon-sidekiq-default-replicas
kubectl get deployment mastodon-sidekiq-background -n mastodon -o jsonpath='{.spec.replicas}' > /tmp/mastodon-sidekiq-background-replicas
kubectl get deployment mastodon-sidekiq-federation -n mastodon -o jsonpath='{.spec.replicas}' > /tmp/mastodon-sidekiq-federation-replicas
kubectl get deployment mastodon-streaming -n mastodon -o jsonpath='{.spec.replicas}' > /tmp/mastodon-streaming-replicas
```

### Phase 2: Migration Execution (5-15 Minutes Downtime)

#### Step 2.1: Enable Migration Job
```bash
# Enable the main migration job
sed -i 's/# - zalando-to-cnpg-migration.yaml/- zalando-to-cnpg-migration.yaml/' kustomization.yaml
kubectl apply -k .
```

#### Step 2.2: Execute Migration
```bash
# Start the migration (this will scale down applications)
kubectl create job zalando-to-cnpg-migration-$(date +%Y%m%d-%H%M) --from=job/zalando-to-cnpg-migration -n mastodon

# Monitor migration progress
kubectl logs -f job/zalando-to-cnpg-migration-$(date +%Y%m%d-%H%M) -n mastodon
```

**Critical Monitoring Points**:
1. **Application Scale Down** (1-2 minutes)
   ```bash
   # Verify applications are scaled down
   kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"
   ```

2. **Backup Creation** (2-5 minutes)
   - Watch for "Creating Final Backup from Zalando" message
   - Monitor backup file size growth

3. **Data Restoration** (3-10 minutes)
   - Watch for "Restoring to CNPG Database" message
   - Monitor for any restoration errors

4. **Basic Validation** (30 seconds)
   - Watch for row count comparisons
   - Verify no mismatches

5. **Application Scale Up** (1-2 minutes)
   - Applications automatically restore to original scale
   - Verify pods are starting successfully

#### Step 2.3: Immediate Post-Migration Checks
```bash
# Verify CNPG database has data
kubectl exec -it $(kubectl get pods -n mastodon -l cnpg.io/cluster=database -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT COUNT(*) FROM accounts;"

# Check application connectivity
kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"
```

### Phase 3: Post-Migration Validation (No Additional Downtime)

#### Step 3.1: Comprehensive Validation
```bash
# Enable validation job
sed -i 's/# - cnpg-validation-job.yaml/- cnpg-validation-job.yaml/' kustomization.yaml
kubectl apply -k .

# Run comprehensive validation
kubectl create job cnpg-validation-$(date +%Y%m%d-%H%M) --from=job/cnpg-validation-job -n mastodon

# Monitor validation
kubectl logs -f job/cnpg-validation-$(date +%Y%m%d-%H%M) -n mastodon
```

**Validation Checks**:
- Schema integrity (tables, indexes, constraints)
- Data consistency (row counts, referential integrity)
- Performance benchmarks
- SSL configuration
- Read-only endpoint functionality
- Extension availability

#### Step 3.2: Application Configuration Update

**Update Database Endpoints** (requires application restart):
```bash
# Update mastodon-database.env to use CNPG endpoints
# Change from: mastodon-postgresql-pooler
# Change to: database-pooler-rw

# For read-only queries:
# Change from: mastodon-postgresql-repl
# Change to: database-pooler-ro
```

#### Step 3.3: Monitor Application Health
```bash
# Check application logs for database errors
kubectl logs -f deployment/mastodon-web -n mastodon
kubectl logs -f deployment/mastodon-sidekiq-default -n mastodon

# Monitor database connections
kubectl exec -it $(kubectl get pods -n mastodon -l cnpg.io/cluster=database -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT application_name, count(*) FROM pg_stat_activity WHERE state = 'active' GROUP BY application_name;"
```

### Phase 4: Stabilization Period (24-48 Hours)

#### Step 4.1: Monitoring Checklist
- [ ] All Mastodon functions working (posting, following, notifications)
- [ ] No database connection errors in application logs
- [ ] CNPG backups running successfully
- [ ] Performance metrics stable
- [ ] No data consistency issues reported

#### Step 4.2: Performance Baseline
```bash
# Create performance baseline after 24 hours
kubectl create job cnpg-performance-baseline --from=job/cnpg-validation-job -n mastodon
```

### Phase 5: Cleanup (After 7+ Days of Stable Operation)

#### Step 5.1: Final Validation
```bash
# Ensure CNPG has been stable for at least 7 days
# Check monitoring dashboards
# Verify no Zalando connections

# Run final validation
kubectl create job cnpg-final-validation --from=job/cnpg-validation-job -n mastodon
```

#### Step 5.2: Zalando Cleanup (Optional)
```bash
# Enable cleanup job (DANGEROUS - READ THE CODE FIRST)
sed -i 's/# - zalando-cleanup-job.yaml/- zalando-cleanup-job.yaml/' kustomization.yaml
kubectl apply -k .

# Review the cleanup job code before running
kubectl get job zalando-cleanup-job -n mastodon -o yaml

# Execute cleanup (uncomment specific actions in the job first)
kubectl create job zalando-cleanup-$(date +%Y%m%d) --from=job/zalando-cleanup-job -n mastodon
```

## Timing and Downtime Analysis

### Downtime Breakdown
| Phase | Duration | Impact |
|-------|----------|---------|
| Application Scale Down | 1-2 minutes | Full downtime begins |
| Final Backup Creation | 2-5 minutes | Downtime continues |
| Data Restoration | 3-10 minutes | Downtime continues |
| Basic Validation | 30 seconds | Downtime continues |
| Application Scale Up | 1-2 minutes | Downtime ends |
| **Total Downtime** | **7-20 minutes** | **Full service unavailable** |

### Database Size Impact
| Database Size | Backup Time | Restore Time | Total Downtime |
|---------------|-------------|--------------|----------------|
| < 1GB | 1-2 minutes | 2-3 minutes | 5-8 minutes |
| 1-5GB | 2-3 minutes | 3-5 minutes | 7-12 minutes |
| 5-20GB | 3-5 minutes | 5-10 minutes | 10-18 minutes |
| > 20GB | 5+ minutes | 10+ minutes | 18+ minutes |

## Potential Issues and Troubleshooting

### Issue 1: Migration Job Fails During Backup
**Symptoms**:
- Job logs show `pg_dump` errors
- Connection refused errors

**Troubleshooting**:
```bash
# Check Zalando database health
kubectl get postgresql mastodon-postgresql -n mastodon
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U postgres -c "SELECT version();"

# Check connectivity
kubectl exec -it $(kubectl get pods -n mastodon -l app=mastodon-web -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  pg_isready -h mastodon-postgresql-pooler -p 5432
```

**Resolution**:
- Wait for Zalando to stabilize
- Check resource constraints
- Retry migration during lower load

### Issue 2: CNPG Restoration Fails
**Symptoms**:
- `psql` restoration errors
- Transaction rollback messages
- Constraint violation errors

**Troubleshooting**:
```bash
# Check CNPG cluster health
kubectl get cluster database -n mastodon
kubectl describe cluster database -n mastodon

# Check available storage
kubectl get pvc -n mastodon | grep database

# Check logs
kubectl logs -l cnpg.io/cluster=database -n mastodon
```

**Resolution**:
- Verify CNPG cluster is healthy
- Check available storage space
- Clean CNPG database and retry
- Scale up CNPG resources if needed

### Issue 3: Applications Won't Connect to CNPG
**Symptoms**:
- Connection refused errors in app logs
- Database timeout errors
- SSL/TLS handshake failures

**Troubleshooting**:
```bash
# Test CNPG connectivity
kubectl exec -it $(kubectl get pods -n mastodon -l app=mastodon-web -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  pg_isready -h database-pooler-rw -p 5432

# Check SSL certificates
kubectl get secret mastodon-postgresql-ca -n mastodon -o yaml

# Verify pooler status
kubectl get pooler -n mastodon
kubectl describe pooler database-pooler-rw -n mastodon
```

**Resolution**:
- Update application configuration
- Verify SSL certificate compatibility
- Check pooler resource limits
- Restart application pods

### Issue 4: Data Consistency Problems
**Symptoms**:
- Row count mismatches
- Missing data in applications
- Referential integrity errors

**Troubleshooting**:
```bash
# Compare key table counts
kubectl exec -it $(kubectl get pods -n mastodon -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U postgres -d mastodon -c "SELECT 'accounts', COUNT(*) FROM accounts UNION ALL SELECT 'statuses', COUNT(*) FROM statuses;"

kubectl exec -it $(kubectl get pods -n mastodon -l cnpg.io/cluster=database -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT 'accounts', COUNT(*) FROM accounts UNION ALL SELECT 'statuses', COUNT(*) FROM statuses;"

# Check for foreign key violations
kubectl exec -it $(kubectl get pods -n mastodon -l cnpg.io/cluster=database -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT COUNT(*) FROM users WHERE account_id NOT IN (SELECT id FROM accounts);"
```

**Resolution**:
- Perform rollback to Zalando
- Investigate backup integrity
- Re-run migration with fresh backup

### Issue 5: Performance Degradation
**Symptoms**:
- Slower response times
- High database load
- Connection pool exhaustion

**Troubleshooting**:
```bash
# Check CNPG resource usage
kubectl top pods -n mastodon | grep database

# Monitor active connections
kubectl exec -it $(kubectl get pods -n mastodon -l cnpg.io/cluster=database -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"

# Check slow queries
kubectl exec -it $(kubectl get pods -n mastodon -l cnpg.io/cluster=database -o jsonpath='{.items[0].metadata.name}') -n mastodon -- \
  psql -U postgres -d mastodon -c "SELECT query, mean_exec_time FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 10;"
```

**Resolution**:
- Scale up CNPG resources
- Tune PostgreSQL configuration
- Increase pooler connections
- Consider read replica usage

## Rollback Procedures

### Emergency Rollback (During Migration)
If issues occur during the migration:

```bash
# 1. Stop the migration job
kubectl delete job zalando-to-cnpg-migration-$(date +%Y%m%d-%H%M) -n mastodon

# 2. Manually restore application scaling
kubectl scale deployment mastodon-web --replicas=$(cat /tmp/mastodon-web-replicas) -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=$(cat /tmp/mastodon-sidekiq-default-replicas) -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=$(cat /tmp/mastodon-sidekiq-background-replicas) -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=$(cat /tmp/mastodon-sidekiq-federation-replicas) -n mastodon
kubectl scale deployment mastodon-streaming --replicas=$(cat /tmp/mastodon-streaming-replicas) -n mastodon

# 3. Verify applications are healthy with Zalando
kubectl get pods -n mastodon | grep -E "(mastodon-web|mastodon-sidekiq|mastodon-streaming)"
```

### Post-Migration Rollback (Within 48 Hours)
If issues are discovered after migration:

```bash
# 1. Scale down applications
kubectl scale deployment mastodon-web --replicas=0 -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=0 -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=0 -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=0 -n mastodon
kubectl scale deployment mastodon-streaming --replicas=0 -n mastodon

# 2. Revert database configuration to Zalando endpoints
# Edit mastodon-database.env to use:
# DB_HOST=mastodon-postgresql-pooler
# REPLICA_DB_HOST=mastodon-postgresql-repl

# 3. Apply configuration changes
kubectl apply -k kubernetes/apps/platform/mastodon/

# 4. Restore applications
kubectl scale deployment mastodon-web --replicas=$(cat /tmp/mastodon-web-replicas) -n mastodon
kubectl scale deployment mastodon-sidekiq-default --replicas=$(cat /tmp/mastodon-sidekiq-default-replicas) -n mastodon
kubectl scale deployment mastodon-sidekiq-background --replicas=$(cat /tmp/mastodon-sidekiq-background-replicas) -n mastodon
kubectl scale deployment mastodon-sidekiq-federation --replicas=$(cat /tmp/mastodon-sidekiq-federation-replicas) -n mastodon
kubectl scale deployment mastodon-streaming --replicas=$(cat /tmp/mastodon-streaming-replicas) -n mastodon
```

## Success Criteria

### Migration Success
- [ ] All migration jobs complete without errors
- [ ] Data validation passes (matching row counts)
- [ ] Applications connect successfully to CNPG
- [ ] No increase in error rates
- [ ] Performance metrics within acceptable range
- [ ] SSL connections working
- [ ] Backup system operational

### Long-term Success (After 7 Days)
- [ ] Zero database-related incidents
- [ ] Performance stable or improved
- [ ] Backup/restore procedures validated
- [ ] Monitoring showing healthy metrics
- [ ] No user-reported issues

## Maintenance Windows

### Recommended Schedule
1. **Pre-migration testing**: During business hours (low risk)
2. **Migration execution**: Early morning UTC (2-6 AM)
3. **Post-migration monitoring**: 24-48 hours of enhanced monitoring
4. **Cleanup**: During next scheduled maintenance window

### Communication Plan
- **T-24 hours**: Announce maintenance window
- **T-1 hour**: Remind users of impending maintenance
- **T-0**: Begin migration, post status updates
- **T+completion**: Announce completion and any issues
- **T+24 hours**: Provide stability update

## Monitoring and Alerting

### Key Metrics to Watch
- Database connection count
- Query response times
- Application error rates
- Pod restart counts
- Storage usage
- Backup success rates

### Alert Conditions
- Database connectivity failures
- Application error rate > 5%
- Query response time > 2x baseline
- Failed backup attempts
- Pod crash loops

## Conclusion

This migration strategy provides a safe, tested path from Zalando PostgreSQL to CloudNativePG with minimal downtime and comprehensive rollback capabilities. The phased approach ensures each step can be validated before proceeding, and the extensive monitoring and troubleshooting guidance helps address common issues quickly.

The total downtime is limited to the data transfer period (typically 5-15 minutes), while maintaining full rollback capability until the migration is fully validated and stable.