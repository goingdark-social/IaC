# CloudNativePG Migration - Documentation Update Summary

## Overview

The migration documentation has been significantly enhanced based on best practices for production PostgreSQL migrations using pg_dump/pg_restore. This update addresses critical gaps and ensures a robust, production-ready migration process.

## Critical Improvements Made

### 1. **User Privileges Verification** ✅

**Issue**: Original plan assumed `standby` user had sufficient privileges without verification.

**Solution**: Added comprehensive privilege checking:
- Verification that `standby` user has `pg_read_all_data` or superuser role
- Instructions to grant privileges if insufficient
- Alternative: Create dedicated dump user with proper grants
- Pre-migration checklist includes privilege verification

**Documentation**: 
- `MIGRATION-PGDUMP.md` - Section 1.1: "Verify Standby User Privileges"
- `PREFLIGHT-CHECKLIST.md` - Item 3: "Standby User Privileges"

---

### 2. **External Cluster Configuration Clarified** ✅

**Issue**: Migration guide showed `bootstrap.initdb.import` but didn't emphasize the critical `externalClusters` section.

**Solution**: Added dedicated section explaining the connection:
- Detailed explanation of `externalClusters` configuration
- How `source.externalCluster: zalando-cluster` references the cluster definition
- Verification that configuration already exists in `database-cnpg.yaml`
- Pre-flight check to confirm section is present

**Documentation**:
- `MIGRATION-PGDUMP.md` - New section: "Understanding the Configuration"
- `PREFLIGHT-CHECKLIST.md` - Item 1: "External Cluster Configuration"

---

### 3. **Roles Import Verification** ✅

**Issue**: Only `mastodon` role listed without verification of other required roles.

**Solution**: Added role discovery and verification:
- Command to list all non-system roles on source database
- Instructions to add additional roles to import config if needed
- Clarification that `standby` role not needed in CNPG
- Explanation of CNPG auto-generated `app` user vs imported `mastodon` role

**Documentation**:
- `MIGRATION-PGDUMP.md` - Section 4: "Verify Database Roles to Import"
- `MIGRATION-PGDUMP.md` - Post-import section: "Verify Imported Roles"
- `PREFLIGHT-CHECKLIST.md` - Item 8: "Database Roles to Import"

---

### 4. **Disk Space and Storage Verification** ✅

**Issue**: No verification of sufficient disk space for import operation.

**Solution**: Added comprehensive storage checks:
- Database size measurement in GB
- Source disk space verification
- Target PVC size verification (rule: ≥2x database size)
- Instructions to increase PVC sizes if needed
- Explanation of space requirements (data + WAL + temp + growth)

**Documentation**:
- `MIGRATION-PGDUMP.md` - Section 3: "Check Current Database Size and Disk Space"
- `PREFLIGHT-CHECKLIST.md` - Item 7: "Database Size and Disk Space"

---

### 5. **Version Compatibility Verification** ✅

**Issue**: Assumed version compatibility without explicit verification.

**Solution**: Added version checking:
- Source PostgreSQL version check
- Target version verification from config
- Compatibility matrix (same major, minor differences, upgrades, downgrades)
- Both clusters confirmed running PostgreSQL 17.x

**Documentation**:
- `MIGRATION-PGDUMP.md` - Section 5: "Verify PostgreSQL Version Compatibility"
- `PREFLIGHT-CHECKLIST.md` - Item 9: "PostgreSQL Version Compatibility"

---

### 6. **Staging Environment Testing** ✅

**Issue**: No recommendation for dry-run testing before production.

**Solution**: Added staging test procedure:
- Step-by-step staging namespace creation
- Secret copying procedure
- Import test without affecting production
- Benefits explained (timing, privilege verification, app testing)
- Marked as highly recommended but optional

**Documentation**:
- `MIGRATION-PGDUMP.md` - Section 6: "Staging Environment Test"
- `PREFLIGHT-CHECKLIST.md` - Item 10: "Staging Environment Test"

---

### 7. **What Gets Imported - Detailed Breakdown** ✅

**Issue**: Vague description of what `pg_dump --no-owner --no-acl` imports.

**Solution**: Added comprehensive breakdown:
- ✅ Schema objects (tables, indexes, constraints, sequences, views, functions)
- ✅ Data (all rows, large objects, TOAST data)
- ✅ Roles (with password hashes and attributes)
- ❌ Not imported (ownership, ACLs, tablespaces, config, replication)
- Explanation of post-import credential handling (CNPG `app` user)

**Documentation**:
- `MIGRATION-PGDUMP.md` - New section after Step 4: "What Gets Imported"
- `MIGRATION-SUMMARY.md` - Updated section: "What Gets Migrated"

---

### 8. **Enhanced Troubleshooting** ✅

**Issue**: Limited troubleshooting for privilege and import issues.

**Solution**: Added new troubleshooting scenarios:
- Permission denied errors (with privilege grants)
- Missing tables or data after import
- Disk space issues during import
- Enhanced existing sections with more diagnostic commands

**Documentation**:
- `MIGRATION-PGDUMP.md` - Troubleshooting section enhanced

---

### 9. **Pre-Flight Checklist Document** ✅ NEW

**Added**: Comprehensive standalone checklist document:
- All critical verifications in one place
- Status indicators (✅ verified, ⚠️ needs checking)
- Quick verification script for automation
- Summary checklist with must-have vs recommended items

**Documentation**:
- `PREFLIGHT-CHECKLIST.md` - New comprehensive document
- Automated preflight check script included

---

### 10. **Network Connectivity Testing** ✅

**Issue**: Basic connectivity test was incomplete.

**Solution**: Enhanced connectivity verification:
- More robust test command with actual password
- Multiple diagnostic outputs (version, databases, roles)
- Troubleshooting steps if connection fails
- DNS resolution verification

**Documentation**:
- `MIGRATION-PGDUMP.md` - Section 2: Enhanced connectivity test
- `PREFLIGHT-CHECKLIST.md` - Item 5: "Network Connectivity Test"

---

## Documentation Structure

### Primary Documents

1. **MIGRATION-PGDUMP.md** (Enhanced)
   - Comprehensive migration guide (800+ lines)
   - All phases, verification, troubleshooting
   - Production-ready procedures

2. **PREFLIGHT-CHECKLIST.md** (NEW)
   - All prerequisites in one document
   - Verification commands and scripts
   - Go/no-go decision criteria

3. **MIGRATION.md** (Updated)
   - Quick reference guide
   - Points to detailed docs
   - Essential commands only

4. **MIGRATION-SUMMARY.md** (Updated)
   - High-level overview
   - Key changes and benefits
   - Timeline and approach

5. **PR-CHECKLIST.md** (Updated)
   - Deployment checklist
   - Enhanced verification steps
   - Success criteria

---

## Configuration Verification

All critical configurations confirmed present in `database-cnpg.yaml`:

✅ `bootstrap.initdb.import` section with:
- Type: monolith
- Databases: mastodon
- Roles: mastodon
- Source: zalando-cluster
- pg_dump options: --verbose, --format=custom, --no-owner, --no-acl
- pg_restore options: --verbose, --jobs=4, --no-owner, --no-acl

✅ `externalClusters` section with:
- Name: zalando-cluster
- Host: mastodon-postgresql.mastodon.svc.cluster.local
- Port: 5432
- User: standby (from zalando-standby-credentials secret)
- Database: mastodon
- SSL: verify-ca mode with CA cert

✅ TLS certificates configured:
- Server CA: mastodon-postgresql-ca
- Client CA: mastodon-postgresql-ca
- Server TLS: mastodon-postgresql-server
- All CNPG service DNS names included

---

## Critical Actions Required Before Migration

### Must Complete (⚠️):
1. **Verify standby user privileges** - Run privilege check, grant if needed
2. **Measure database size** - Ensure PVC sizes are sufficient (≥2x)
3. **Test network connectivity** - Verify CNPG can reach Zalando cluster
4. **Verify all roles** - Ensure all required roles listed in config
5. **Schedule maintenance window** - Notify users, plan timing

### Highly Recommended (✨):
1. **Run staging test** - Dry-run import, measure time, verify compatibility
2. **Verify backup** - Confirm recent Zalando backup exists
3. **Run preflight script** - Automated check of all prerequisites

### Already Complete (✅):
1. ExternalSecret configured
2. TLS certificates present
3. CNPG operator installed
4. Version compatibility confirmed (both PostgreSQL 17)
5. Import configuration present in manifest

---

## Migration Approach Comparison

| Aspect | Previous (pg_basebackup) | Current (pg_dump) |
|--------|-------------------------|-------------------|
| **Method** | Physical binary replication | Logical SQL backup |
| **Downtime** | Minimal (streaming replica) | 15-30 min maintenance |
| **Complexity** | Higher (WAL streaming) | Lower (standard tools) |
| **Verification** | Complex (check WAL lag) | Simple (compare counts) |
| **Version Flexibility** | Same major version only | Any compatible version |
| **Privilege Requirements** | Replication role | Read-only access |
| **Documentation** | Moderate | Comprehensive |
| **Production Readiness** | Good | Excellent |

**Recommendation**: pg_dump approach is safer for production due to:
- Better verification points
- Simpler rollback
- Well-documented procedures
- Industry-standard tool

---

## Testing and Validation

### Kustomize Build
```bash
kustomize build kubernetes/apps/platform/mastodon/resources/workloads
```
**Status**: ✅ Passes

### Configuration Validation
```bash
yq eval '.spec.bootstrap.initdb.import' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
yq eval '.spec.externalClusters' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```
**Status**: ✅ Both sections present and correct

---

## Next Steps for Migration Execution

1. **Review all documentation**:
   - Read `PREFLIGHT-CHECKLIST.md` first
   - Run automated preflight check script
   - Review `MIGRATION-PGDUMP.md` thoroughly

2. **Complete prerequisites**:
   - Verify standby user privileges
   - Measure database size and confirm disk space
   - Test network connectivity
   - Optional: Run staging test

3. **Schedule and communicate**:
   - Choose maintenance window (low-traffic period)
   - Notify users 24-48 hours in advance
   - Prepare rollback communication

4. **Execute migration**:
   - Follow `MIGRATION-PGDUMP.md` Phase 1 (zero downtime)
   - Verify import completed successfully
   - Schedule cutover window
   - Follow Phase 2 (maintenance window)

5. **Post-migration**:
   - Monitor for 24-48 hours
   - Verify backups working
   - Clean up Zalando resources after stable operation

---

## Support and References

**Internal Documentation**:
- `PREFLIGHT-CHECKLIST.md` - Pre-migration verification
- `MIGRATION-PGDUMP.md` - Complete migration guide
- `MIGRATION.md` - Quick reference
- `MIGRATION-SUMMARY.md` - Overview
- `PR-CHECKLIST.md` - Deployment checklist

**External References**:
- [CloudNativePG Import Docs](https://cloudnative-pg.io/documentation/current/bootstrap/#import-existing-databases)
- [PostgreSQL pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html)
- [PostgreSQL pg_restore](https://www.postgresql.org/docs/current/app-pgrestore.html)

---

**Documentation Status**: ✅ Complete and Production-Ready
**Configuration Status**: ✅ Validated
**Next Action**: Complete pre-flight checklist items before proceeding
