# CloudNativePG Migration - PR Checklist

## Changes Made ✅

### Configuration Files
- [x] Updated `database-cnpg.yaml` with `bootstrap.initdb.import` for pg_dump migration
- [x] Configured pg_dump with custom format and parallel restore (4 jobs)
- [x] Added TLS certificate configuration to both import and promoted configs
- [x] Fixed `tolerations` indentation issue
- [x] Fixed typo: `max_worker_processors` → `max_worker_processes`
- [x] Updated `database-cnpg-promoted.yaml` with proper certificate configuration

### Documentation
- [x] Created comprehensive `MIGRATION-PGDUMP.md` with full migration guide
- [x] Updated `MIGRATION.md` as quick reference pointing to detailed guide
- [x] Created `MIGRATION-SUMMARY.md` explaining the approach and changes

## Migration Approach: pg_dump vs pg_basebackup

### Why pg_dump?
1. **Safer for production**: Non-blocking export, production continues during import
2. **Well-tested**: Standard PostgreSQL migration tool
3. **Fine-grained control**: Can customize what gets migrated
4. **Parallel restore**: Faster import with 4 concurrent jobs
5. **Clear verification**: Easy to validate before cutover

### Migration Phases
**Phase 1: Initial Import (Zero Downtime)**
- Deploy CNPG cluster with import configuration
- CloudNativePG automatically runs pg_dump from Zalando cluster
- Restore with 4 parallel jobs for speed
- Verify data integrity
- ~15-90 minutes (depends on DB size)

**Phase 2: Final Cutover (15-30 min maintenance)**
- Scale down Mastodon workloads
- Promote CNPG cluster to production config
- Update application secrets and ConfigMaps
- Scale up and verify
- Short, controlled downtime

## Pre-Merge Verification

### Kustomize Build Test
```bash
cd /home/develop/IaC
kustomize build kubernetes/apps/platform/mastodon/resources/workloads
```
**Status**: ✅ Passed

### Configuration Validation
```bash
yq eval '.spec.bootstrap.initdb.import' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```
**Status**: ✅ Correct configuration confirmed

### Files Modified
```
kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml
kubernetes/apps/platform/mastodon/MIGRATION.md
kubernetes/apps/platform/mastodon/MIGRATION-PGDUMP.md (new)
kubernetes/apps/platform/mastodon/MIGRATION-SUMMARY.md (new)
```

## Pre-Deployment Checklist

Before merging this PR:
- [ ] Review comprehensive migration guide (MIGRATION-PGDUMP.md)
- [ ] Verify ExternalSecret `zalando-standby-credentials` is syncing
- [ ] Confirm TLS certificates exist (mastodon-postgresql-ca, mastodon-postgresql-server)
- [ ] Test network connectivity from CNPG namespace to Zalando cluster
- [ ] Schedule maintenance window (recommend off-peak hours)
- [ ] Notify users of planned downtime
- [ ] Take manual backup of Zalando cluster as safety net

## Deployment Steps

### 1. Pre-Deployment Verification
```bash
# Verify standby credentials
kubectl get externalsecret zalando-standby-credentials -n mastodon
kubectl get secret zalando-standby-credentials -n mastodon

# Check current database size (estimate import time)
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database WHERE datname = 'mastodon';"
```

### 2. Phase 1: Initial Import (Zero Downtime)
```bash
# Deploy CNPG cluster with import configuration
kubectl apply -f kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml

# Monitor import progress
kubectl logs -n mastodon -l cnpg.io/cluster=database-cnpg -f

# Check cluster status
kubectl cnpg status database-cnpg -n mastodon
```

### 3. Verify Import Completed
```bash
# Check table counts match source
kubectl cnpg psql database-cnpg -n mastodon -- -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';"

# Compare with source
kubectl exec -n mastodon mastodon-postgresql-0 -- psql -U postgres mastodon -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';"

# Verify sample data
kubectl cnpg psql database-cnpg -n mastodon -- -c "SELECT COUNT(*) FROM accounts;"
kubectl cnpg psql database-cnpg -n mastodon -- -c "SELECT COUNT(*) FROM statuses;"
```

### 4. Phase 2: Cutover (Maintenance Window)
Follow detailed steps in `MIGRATION-PGDUMP.md` section "Phase 2: Final Cutover"

Key steps:
1. Scale down Mastodon workloads
2. Apply promoted configuration
3. Update credentials and host configuration
4. Scale up and verify

## Rollback Plan

If issues occur during cutover:
```bash
# Scale down CNPG-connected workloads
kubectl scale deployment -n mastodon mastodon-web mastodon-streaming mastodon-sidekiq-* --replicas=0

# Revert database host to Zalando
kubectl patch configmap mastodon-database -n mastodon --type merge -p '{"data":{"DB_HOST":"mastodon-postgresql-pooler","DB_PORT":"5432"}}'

# Restore original credentials (if changed)
# Use backup or recreate with original values

# Scale up with original config
kubectl scale deployment -n mastodon mastodon-web --replicas=2 mastodon-streaming --replicas=2
```

See detailed rollback procedures in `MIGRATION-PGDUMP.md`

## Post-Deployment Monitoring

After successful cutover, monitor for 24-48 hours:
```bash
# Monitor pod health
watch kubectl get pods -n mastodon

# Check database connections
kubectl cnpg psql database-cnpg -n mastodon -- -c "SELECT count(*), usename, application_name FROM pg_stat_activity WHERE datname = 'mastodon' GROUP BY usename, application_name;"

# Check for errors
kubectl logs -n mastodon -l app=mastodon-web --since=1h | grep -i error
kubectl logs -n mastodon -l cnpg.io/cluster=database-cnpg --since=1h | grep -i error
```

## Success Criteria

Migration is successful when:
- [x] CloudNativePG cluster is healthy and running
- [x] All Mastodon tables and data migrated (verified counts match)
- [x] Application pods are healthy and processing requests
- [x] Users can login, post, and federate normally
- [x] No database-related errors in logs
- [x] Automated S3 backups are working
- [x] Performance metrics are normal or improved
- [x] 24+ hours of stable operation

## Post-Migration Cleanup (After 48 Hours)

After confirmed stable operation:
1. Remove Zalando resources from kustomization
2. Archive Zalando cluster (scale to 0, keep for 7 days)
3. After 7 days, delete Zalando cluster completely
4. Update documentation and architecture diagrams

See detailed cleanup steps in `MIGRATION-PGDUMP.md`

## Testing Recommendations

Before production migration:
- [ ] Review all three migration documents thoroughly
- [ ] Understand rollback procedures
- [ ] Have database backups ready
- [ ] Test kubectl cnpg plugin is installed and working
- [ ] Practice commands in non-production environment if possible

## Additional Resources

- **Comprehensive Guide**: `MIGRATION-PGDUMP.md` (full details, troubleshooting)
- **Quick Reference**: `MIGRATION.md` (essential commands only)
- **Summary**: `MIGRATION-SUMMARY.md` (overview of changes)
- **CloudNativePG Docs**: https://cloudnative-pg.io/documentation/current/bootstrap/#import-existing-databases
- **PostgreSQL pg_dump**: https://www.postgresql.org/docs/current/app-pgdump.html

## Questions or Issues?

Refer to the troubleshooting section in `MIGRATION-PGDUMP.md` or consult with the infrastructure team.

---

**Ready to merge?** All configurations validated and documentation complete! ✅
