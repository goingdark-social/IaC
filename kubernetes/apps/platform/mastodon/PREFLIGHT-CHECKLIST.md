# CloudNativePG Migration - Pre-Flight Checklist

This checklist ensures all prerequisites are met before beginning the migration from Zalando Postgres Operator to CloudNativePG.

## Critical Configuration Verification

### ✅ 1. External Cluster Configuration

**Requirement**: The `database-cnpg.yaml` must define the external cluster connection.

**Verify**:
```bash
yq eval '.spec.externalClusters' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```

**Expected output**:
```yaml
- name: zalando-cluster
  connectionParameters:
    host: mastodon-postgresql.mastodon.svc.cluster.local
    port: "5432"
    user: standby
    dbname: mastodon
    sslmode: verify-ca
  password:
    name: zalando-standby-credentials
    key: password
  sslRootCert:
    name: mastodon-postgresql-ca
    key: ca.crt
```

**Status**: ✅ Present in current configuration

---

### ✅ 2. Bootstrap Import Configuration

**Requirement**: The cluster must have `bootstrap.initdb.import` configured.

**Verify**:
```bash
yq eval '.spec.bootstrap.initdb.import' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```

**Expected output**:
```yaml
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

**Status**: ✅ Present in current configuration

---

## User Privileges Verification

### ⚠️ 3. Standby User Privileges

**Requirement**: The `standby` user must have sufficient privileges to dump all database objects.

**Check privileges**:
```bash
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "
    SELECT 
      rolname,
      rolsuper,
      rolreplication,
      pg_has_role(rolname, 'pg_read_all_data', 'member') as read_all_data,
      pg_has_role(rolname, 'pg_read_all_settings', 'member') as read_all_settings
    FROM pg_roles 
    WHERE rolname = 'standby';
  "
```

**Required**: One of the following:
- ✅ `rolsuper = t` (superuser)
- ✅ `rolreplication = t` AND `read_all_data = t`
- ✅ `read_all_data = t` AND `read_all_settings = t`

**If insufficient, grant privileges**:
```bash
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "
    GRANT pg_read_all_data TO standby;
    GRANT pg_read_all_settings TO standby;
  "
```

**Status**: ⚠️ Needs verification before migration

---

### ✅ 4. Standby User Credentials

**Requirement**: ExternalSecret must sync credentials from Zalando cluster.

**Verify ExternalSecret**:
```bash
kubectl get externalsecret zalando-standby-credentials -n mastodon
```

**Expected**:
```
NAME                          STORE                 REFRESH   STATUS
zalando-standby-credentials   zalando-k8s-store     1h        SecretSynced
```

**Verify Secret exists**:
```bash
kubectl get secret zalando-standby-credentials -n mastodon
```

**Test credentials**:
```bash
kubectl get secret zalando-standby-credentials -n mastodon \
  -o jsonpath='{.data.username}' | base64 -d
echo
kubectl get secret zalando-standby-credentials -n mastodon \
  -o jsonpath='{.data.password}' | base64 -d | wc -c
echo " characters"
```

**Expected**:
- Username: `standby`
- Password: Non-empty (length > 20 characters)

**Status**: ✅ ExternalSecret configured

---

## Network and Connectivity

### ✅ 5. Network Connectivity Test

**Requirement**: CNPG pods must reach Zalando PostgreSQL cluster.

**Test connection**:
```bash
STANDBY_PASS=$(kubectl get secret zalando-standby-credentials -n mastodon -o jsonpath='{.data.password}' | base64 -d)

kubectl run -n mastodon pg-test --rm -it --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:17.5 \
  -- bash -c "
    export PGPASSWORD='$STANDBY_PASS'
    psql -h mastodon-postgresql.mastodon.svc.cluster.local \
         -p 5432 \
         -U standby \
         -d mastodon \
         --set=sslmode=verify-ca \
         -c 'SELECT version();'
  "
```

**Expected**: PostgreSQL version string displayed

**If fails, check**:
- DNS resolution: `nslookup mastodon-postgresql.mastodon.svc.cluster.local`
- Network policies allowing traffic
- Service exists: `kubectl get svc mastodon-postgresql -n mastodon`

**Status**: ⚠️ Needs testing before migration

---

### ✅ 6. TLS Certificates

**Requirement**: CA and server certificates must exist for TLS connections.

**Verify certificates exist**:
```bash
kubectl get secret mastodon-postgresql-ca -n mastodon
kubectl get secret mastodon-postgresql-server -n mastodon
```

**Verify certificate contents**:
```bash
kubectl get secret mastodon-postgresql-ca -n mastodon -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -text -noout | head -20
```

**Expected**: Valid X.509 certificate with appropriate CN and SAN

**Status**: ✅ Certificates configured via cert-manager

---

## Database State and Size

### ⚠️ 7. Database Size and Disk Space

**Requirement**: Sufficient disk space for import (2x DB size recommended).

**Check database size**:
```bash
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "
    SELECT 
      pg_database.datname,
      pg_size_pretty(pg_database_size(pg_database.datname)) AS size,
      pg_database_size(pg_database.datname) / 1024 / 1024 / 1024 AS size_gb
    FROM pg_database
    WHERE datname = 'mastodon';
  "
```

**Check source disk space**:
```bash
kubectl exec -n mastodon mastodon-postgresql-0 -- df -h /home/postgres/pgdata
```

**Check PVC sizes in config**:
```bash
yq eval '.spec.storage.size' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
yq eval '.spec.walStorage.size' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```

**Expected**:
- Current DB size: ___ GB
- CNPG storage PVC: 40Gi (42 GB)
- CNPG WAL PVC: 10Gi (10 GB)
- **Rule**: `storage.size` should be ≥ 2x database size

**If insufficient, update config**:
```yaml
storage:
  size: 80Gi  # Increase as needed
walStorage:
  size: 20Gi  # Increase as needed
```

**Status**: ⚠️ Needs verification based on actual DB size

---

### ⚠️ 8. Database Roles to Import

**Requirement**: All required roles must be listed in import configuration.

**List existing roles**:
```bash
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "
    SELECT 
      rolname,
      rolsuper,
      rolcanlogin,
      rolcreatedb,
      rolreplication
    FROM pg_roles
    WHERE rolname NOT LIKE 'pg_%'
      AND rolname != 'postgres'
    ORDER BY rolname;
  "
```

**Check configured roles**:
```bash
yq eval '.spec.bootstrap.initdb.import.roles' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```

**Expected roles**:
- `mastodon` - Application user ✅ (in config)
- Any other custom roles (add to config if needed)

**Note**: `standby` role not needed in CNPG (it creates its own replication users)

**Status**: ⚠️ Needs verification against actual DB roles

---

### ✅ 9. PostgreSQL Version Compatibility

**Requirement**: Source and target must run compatible PostgreSQL versions.

**Check source version**:
```bash
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "SELECT version();"
```

**Check target version in config**:
```bash
yq eval '.spec.imageName' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
```

**Expected**:
- Source: PostgreSQL 17.x
- Target: `ghcr.io/cloudnative-pg/postgresql:17.5`
- ✅ Both major version 17 (compatible)

**Status**: ✅ Both running PostgreSQL 17

---

## Pre-Migration Testing

### 🔄 10. Staging Environment Test

**Recommendation**: Perform dry-run in non-production environment.

**Benefits**:
- Measure actual import time
- Verify privileges are sufficient
- Test application compatibility
- Practice cutover procedure
- Identify issues before production

**Test procedure**:
```bash
# 1. Create staging namespace
kubectl create namespace mastodon-staging

# 2. Copy required secrets
for secret in zalando-standby-credentials mastodon-postgresql-ca mastodon-postgresql-server; do
  kubectl get secret -n mastodon $secret -o yaml | \
    sed 's/namespace: mastodon/namespace: mastodon-staging/' | \
    kubectl apply -f -
done

# 3. Deploy CNPG to staging (pointing to production Zalando)
# Modify database-cnpg.yaml with staging namespace
# Apply and monitor import

# 4. Verify data and measure time
# 5. Delete staging resources
```

**Status**: ⚠️ Recommended but optional (skip if time-constrained)

---

## Backup and Rollback Preparation

### ✅ 11. Zalando Cluster Backup

**Requirement**: Recent backup of source cluster exists and is verified.

**Check backup status**:
```bash
# For Zalando operator with WAL-E/WAL-G
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  envdir /run/etc/wal-e.d/env wal-g backup-list

# Or check via Zalando operator
kubectl get postgresql mastodon-postgresql -n mastodon -o yaml | grep -A5 backup
```

**Verify backup recency**:
- Last backup: < 24 hours old
- Backup status: Successful
- Backup size: Matches database size

**If no recent backup, trigger one**:
```bash
# Trigger manual backup via Zalando operator
# (Specific command depends on backup configuration)
```

**Status**: ⚠️ Needs verification before migration

---

### ✅ 12. Maintenance Window Scheduled

**Requirement**: Users notified and window scheduled during low-traffic period.

**Recommended window**:
- Duration: 1-2 hours (actual downtime 15-30 min)
- Time: Off-peak hours (early morning UTC)
- Day: Weekday (avoid weekends for support availability)

**Notification checklist**:
- [ ] Post on Mastodon instance (24h notice)
- [ ] Update status page if available
- [ ] Notify team members
- [ ] Prepare rollback communication

**Status**: ⚠️ Schedule before proceeding

---

## Summary Checklist

Before proceeding with migration:

**Configuration** (must be ✅):
- [x] `externalClusters` section present in database-cnpg.yaml
- [x] `bootstrap.initdb.import` section present in database-cnpg.yaml
- [x] TLS certificates exist (mastodon-postgresql-ca, mastodon-postgresql-server)
- [x] PostgreSQL version compatibility confirmed (both v17)

**Credentials and Access** (must be ✅):
- [x] ExternalSecret syncing standby credentials
- [ ] **Standby user privileges verified** (⚠️ VERIFY)
- [ ] **Network connectivity tested** (⚠️ TEST)

**Capacity and Resources** (must be ✅):
- [ ] **Database size measured** (⚠️ CHECK)
- [ ] **Disk space sufficient** (≥2x DB size) (⚠️ VERIFY)
- [ ] **All required roles identified** (⚠️ VERIFY)

**Safety and Preparedness** (recommended):
- [ ] Zalando cluster backup verified (⚠️ RECOMMENDED)
- [ ] Staging test completed (optional)
- [ ] Maintenance window scheduled (⚠️ REQUIRED)
- [ ] Rollback plan reviewed

---

## Quick Verification Script

Run this script to check all critical items:

```bash
#!/bin/bash
set -e

echo "=== CloudNativePG Migration Pre-Flight Checks ==="
echo

echo "1. Checking ExternalSecret..."
kubectl get externalsecret zalando-standby-credentials -n mastodon || echo "❌ FAIL"
echo

echo "2. Checking standby credentials secret..."
kubectl get secret zalando-standby-credentials -n mastodon || echo "❌ FAIL"
echo

echo "3. Checking TLS certificates..."
kubectl get secret mastodon-postgresql-ca mastodon-postgresql-server -n mastodon || echo "❌ FAIL"
echo

echo "4. Checking standby user privileges..."
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "
    SELECT 
      CASE 
        WHEN rolsuper THEN '✅ Superuser'
        WHEN pg_has_role(rolname, 'pg_read_all_data', 'member') THEN '✅ Has pg_read_all_data'
        ELSE '❌ INSUFFICIENT PRIVILEGES'
      END as privilege_status
    FROM pg_roles 
    WHERE rolname = 'standby';
  "
echo

echo "5. Checking database size..."
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "
    SELECT 
      pg_database.datname,
      pg_size_pretty(pg_database_size(pg_database.datname)) AS size
    FROM pg_database
    WHERE datname = 'mastodon';
  "
echo

echo "6. Checking PostgreSQL version..."
kubectl exec -n mastodon mastodon-postgresql-0 -- \
  psql -U postgres -c "SELECT version();"
echo

echo "7. Checking CNPG configuration..."
yq eval '.spec.bootstrap.initdb.import.source.externalCluster' kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
echo

echo "=== Pre-Flight Checks Complete ==="
echo "Review output above and resolve any ❌ FAIL items before migration."
```

**Save as**: `preflight-check.sh`
**Run**: `chmod +x preflight-check.sh && ./preflight-check.sh`

---

## Next Steps

After all checks pass:
1. ✅ All items above verified
2. ✅ Team members notified
3. ✅ Maintenance window scheduled
4. 🚀 Proceed to **MIGRATION-PGDUMP.md** Phase 1
