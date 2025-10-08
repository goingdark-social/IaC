# CloudNativePG Migration - pg_dump Approach

## Summary of Changes

This update transitions the CloudNativePG migration from physical replication (`pg_basebackup`) to logical backup (`pg_dump/pg_restore`) for a safer, more controlled production migration.

## Files Changed

### 1. **database-cnpg.yaml** - Initial Import Configuration
**Location**: `kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml`

**Key Changes**:
- ✅ Added `bootstrap.initdb.import` configuration for pg_dump-based migration
- ✅ Configured pg_dump with custom format (`--format=custom`) for parallel restore
- ✅ Set `--jobs=4` for pg_restore to speed up import using parallel workers
- ✅ Added `--no-owner` and `--no-acl` to avoid ownership/permission issues
- ✅ Added TLS certificate configuration with all CNPG service DNS names
- ✅ Fixed `tolerations` indentation (was incorrectly nested under `affinity`)
- ✅ Fixed typo: `max_worker_processors` → `max_worker_processes`

**Configuration Details**:
```yaml
bootstrap:
  initdb:
    import:
      type: monolith
      databases:
        - mastodon
      roles:
        - mastodon
      source:
        externalCluster: zalando-cluster
      pgDumpExtraOptions:
        - "--verbose"
        - "--format=custom"
        - "--no-owner"
        - "--no-acl"
      pgRestoreExtraOptions:
        - "--verbose"
        - "--jobs=4"
        - "--no-owner"
        - "--no-acl"
```

### 2. **database-cnpg-promoted.yaml** - Post-Cutover Configuration
**Location**: `kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml`

**Key Changes**:
- ✅ Updated TLS certificate configuration to match the import configuration
- ✅ Includes all CNPG service DNS names for poolers and read-write endpoints
- ✅ Production-ready with 2 instances, S3 backups, and WAL archiving

### 3. **MIGRATION-PGDUMP.md** - Comprehensive Migration Guide
**Location**: `kubernetes/apps/platform/mastodon/MIGRATION-PGDUMP.md`

**New comprehensive guide includes**:
- ✅ Detailed explanation of why pg_dump/pg_restore is preferred
- ✅ Prerequisites and verification steps
- ✅ Phase 1: Zero-downtime initial import
- ✅ Phase 2: Short maintenance window cutover (15-30 min)
- ✅ Step-by-step commands with explanations
- ✅ Data integrity verification procedures
- ✅ Rollback procedures
- ✅ Troubleshooting section
- ✅ Monitoring and alerting guidance
- ✅ Post-migration cleanup

### 4. **MIGRATION.md** - Quick Reference Updated
**Location**: `kubernetes/apps/platform/mastodon/MIGRATION.md`

**Changes**:
- ✅ Converted to quick reference format
- ✅ References comprehensive MIGRATION-PGDUMP.md for details
- ✅ Simplified to essential commands only
- ✅ Added rollback quick reference
- ✅ Added troubleshooting quick checks

## Migration Strategy: pg_dump vs pg_basebackup

### Previous Approach (pg_basebackup)
- Physical binary replication from Zalando cluster
- Creates streaming replica that follows source WAL
- Requires same PostgreSQL major version
- Faster for large databases but more complex cutover

### New Approach (pg_dump/pg_restore)
- **Logical backup** - exports SQL statements and data
- **Non-blocking** - runs on source without locking
- **Version-agnostic** - works across PostgreSQL versions
- **Fine-grained control** - can selectively migrate objects
- **Parallel restore** - uses 4 jobs for faster import
- **Well-tested** - standard PostgreSQL migration tool

## Migration Timeline

| Phase | Duration | Downtime |
|-------|----------|----------|
| **Phase 1: Initial Import** | 15-90 min* | ❌ No |
| - Deploy CNPG cluster | 2 min | ❌ No |
| - pg_dump export | 10-60 min* | ❌ No |
| - pg_restore import | 5-30 min* | ❌ No |
| **Phase 2: Cutover** | 15-30 min | ✅ Yes |
| - Scale down apps | 2 min | ✅ Yes |
| - Promote cluster | 1 min | ✅ Yes |
| - Update secrets/config | 3 min | ✅ Yes |
| - Database tasks | 2 min | ✅ Yes |
| - Scale up apps | 5 min | ✅ Yes |
| - Verify health | 5-10 min | ✅ Yes |

*Depends on database size (see estimates in MIGRATION-PGDUMP.md)

**Total Downtime**: 15-30 minutes

## Key Benefits

### 1. **Safety**
- Initial import runs while production continues on Zalando cluster
- No risk to production during import phase
- Clear verification points before cutover
- Easy rollback if issues detected

### 2. **Control**
- `--no-owner` and `--no-acl` flags prevent permission issues
- Can customize what gets migrated
- Parallel restore speeds up import
- Clear separation between import and cutover phases

### 3. **Simplicity**
- Standard PostgreSQL tools (pg_dump/pg_restore)
- Well-documented and widely used
- No streaming replication complexity
- Clear success/failure indicators in logs

### 4. **Repeatability**
- Can dry-run import multiple times
- Can test on non-production clusters first
- Automated via CloudNativePG bootstrap

## What Gets Migrated

The `bootstrap.initdb.import` configuration migrates:
- ✅ All tables and data in the `mastodon` database
- ✅ Indexes and constraints
- ✅ Sequences (with current values)
- ✅ Views and materialized views
- ✅ Functions and procedures
- ✅ The `mastodon` role (application user)
- ❌ Ownership (handled by CNPG auto-generated credentials)
- ❌ ACLs (permissions set by CNPG)

## Verification Checklist

Before migration:
- [ ] ExternalSecret syncing Zalando standby credentials
- [ ] Network connectivity from CNPG to Zalando cluster
- [ ] TLS certificates configured
- [ ] Maintenance window scheduled

During Phase 1 (Initial Import):
- [ ] CNPG cluster pod running
- [ ] Import logs show pg_dump started
- [ ] Import logs show pg_restore started with 4 jobs
- [ ] Import completed successfully
- [ ] Table counts match source
- [ ] Sample data queries return expected results

During Phase 2 (Cutover):
- [ ] All Mastodon pods scaled to 0
- [ ] CNPG promoted configuration applied
- [ ] New credentials retrieved
- [ ] Secrets and ConfigMaps updated
- [ ] Mastodon pods healthy after scale-up
- [ ] Application functional testing passed
- [ ] No errors in logs

After Migration (24-48 hours):
- [ ] Backups working (S3 scheduled backups)
- [ ] No performance degradation
- [ ] No database errors
- [ ] Poolers functioning correctly
- [ ] Ready to remove Zalando resources

## Next Steps

1. **Review the comprehensive guide**: Read `MIGRATION-PGDUMP.md` thoroughly
2. **Test connectivity**: Verify ExternalSecret and network access
3. **Schedule maintenance**: Choose low-traffic time window
4. **Execute Phase 1**: Deploy CNPG cluster and monitor import
5. **Verify import**: Check table counts and sample data
6. **Execute Phase 2**: Cutover during maintenance window
7. **Monitor closely**: Watch for 24-48 hours
8. **Cleanup**: Remove Zalando resources after stable operation

## Support

For questions or issues:
- Review troubleshooting section in MIGRATION-PGDUMP.md
- Check CloudNativePG operator logs
- Consult with infrastructure team

---

**Ready to proceed?** Start with Phase 1 in `MIGRATION-PGDUMP.md`!
