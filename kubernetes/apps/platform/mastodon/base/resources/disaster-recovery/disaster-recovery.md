# CloudNativePG Disaster Recovery Guide

This document describes disaster recovery (DR) procedures for the Mastodon PostgreSQL database managed by CloudNativePG.  
**Validated on: December 15, 2025** – Successful full recovery executed using point-in-time recovery (PITR) after complete data loss.


## Table of Contents
- [Architecture Overview](#architecture-overview)
- [Backup Infrastructure](#backup-infrastructure)
- [Disaster Recovery Scenarios](#disaster-recovery-scenarios)
- [Procedure Selection](#procedure-selection)
- [Recovery Procedures](#recovery-procedures)
- [Validated Production Recovery Procedure (Recommended)](#validated-production-recovery-procedure-recommended)
- [Legacy Procedure: Separate Recovery Cluster](#legacy-procedure-separate-recovery-cluster)
- [Verification Procedures](#verification-procedures)
- [Troubleshooting](#troubleshooting)

## Procedure Selection
- **Validated Production Recovery (Recommended)**: Use for actual disasters. Restores directly to the original cluster name → no application config changes required.
- **Legacy Procedure**: Use only for non-production testing or dry runs. Requires a separate cluster name and eventual config updates.

## Architecture Overview
```
┌─────────────────────────────────────────────────────────────────────┐
│ Primary Kubernetes Cluster                                          │
│                                                                     │
│ ┌───────────────────┐      WAL Archive      ┌────────────────────────┐ │
│ │ database-cnpg     │ ─────────────────────▶ │ Cloudflare R2 (S3)     │ │
│ │ (Primary)         │   Base Backups        │ mastovault bucket      │ │
│ │ - PostgreSQL 17   │ ─────────────────────▶ │ /cnpg/mastodon-database│ │
│ │ - 2 instances     │   (Daily @ 06:00)     │ ├── base/              │ │
│ └───────────────────┘                         │ └── wals/              │ │
└─────────────────────────────────────────────────────────────────────┘
```

## Backup Infrastructure
### Current Configuration
| Component              | Value                                                                 |
|------------------------|-----------------------------------------------------------------------|
| **Backup Storage**     | Cloudflare R2 (S3-compatible)                                         |
| **Bucket**             | `mastovault`                                                          |
| **Path**               | `s3://mastovault/cnpg/mastodon-database`                              |
| **WAL Archiving**      | Enabled with gzip compression                                         |
| **WAL Parallelism**    | 8 concurrent uploads                                                  |
| **Base Backup Schedule**| Daily at 06:00 UTC                                                    |
| **Retention Policy**   | 14 days                                                               |
| **Backup Method**      | barman-cloud plugin                                                   |

### Server Identity
`serverName` is the logical identity of the cluster in Barman.  
- Recovery **must** reference the original `serverName` (`database-cnpg`).  
- Post-recovery WAL archiving **must** use a different `serverName` and `destinationPath` to avoid conflicts.

> **WARNING**: Reusing the same path with a different `serverName` will trigger CloudNativePG safety checks and block the cluster (`WAL archive check failed`).

### Backup Verification
```bash
kubectl exec -it database-cnpg-1 -n mastodon -c postgres -- \
  barman-cloud-backup-list \
  --cloud-provider aws-s3 \
  --endpoint-url https://a694d529ab7d7176bcac8585f8bafdf4.r2.cloudflarestorage.com \
  s3://mastovault/cnpg/mastodon-database database-cnpg
```

## Disaster Recovery Scenarios
| Scenario                  | Method                  | Data Loss                  |
|---------------------------|-------------------------|----------------------------|
| Complete cluster loss     | Full recovery to production name | Up to PITR target (validated to 2025-12-15 14:00 UTC) |

## Recovery Procedures


### Validated Production Recovery Procedure (Recommended)
**Goal**: Restore directly into the **original cluster name** (`database-cnpg`) with zero application config changes.


#### Step 1: Scale Down Applications
```bash
kubectl scale deployment -n mastodon \
  mastodon-web mastodon-streaming \
  mastodon-sidekiq-default mastodon-sidekiq-federation \
  mastodon-sidekiq-background mastodon-sidekiq-scheduler \
  mastodon-onion --replicas=0
```


#### Step 2: Full Cleanup of Database Resources
```bash
kubectl delete cluster database-cnpg -n mastodon --wait=true --timeout=5m
kubectl delete pooler database-cnpg-pooler-ro database-cnpg-pooler-rw -n mastodon --wait=true
kubectl delete pvc -n mastodon --selector=cnpg.io/cluster=database-cnpg --wait=true

# Force delete stuck PVCs if necessary
kubectl delete pvc database-cnpg-1 database-cnpg-1-wal -n mastodon --force --grace-period=0
```

Verify cleanup:
```bash
kubectl get cluster,pooler,pvc -n mastodon | grep database-cnpg || echo "All database resources deleted"
```

#### Prerequisites: ObjectStore Resources
Ensure these two ObjectStore resources exist in the namespace (typically already present in production setups):

- `database-backup`: Points to `s3://mastovault/cnpg/mastodon-database` (read-only for recovery, uses original `serverName: database-cnpg`)
- `database-backup-recovered`: Points to a new path (e.g. `s3://mastovault/cnpg/mastodon-database-recovered`) with a different `serverName` for post-recovery backups


#### Step 3: Modify Production Cluster Manifest for Recovery
Edit `database-cnpg.yaml` (production manifest):

```yaml
spec:
  instances: 2
  storage:
    size: 20Gi
  walStorage:
    size: 5Gi  # Temporary due to quota; restore to 20Gi when possible

  bootstrap:
    recovery:
      source: backup-source
      recoveryTarget:
        targetTime: "2025-12-15 14:00:00+00" # Choose latest possible time before disaster
        targetTLI: "4" # Find via: barman-cloud-backup-show ... | grep "Timeline"

  externalClusters:
    - name: backup-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: database-backup
          serverName: database-cnpg

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: database-backup-recovered
        serverName: database-cnpg-recovered   # Different to avoid conflicts
```

> **Key Fixes Applied**:
> - PITR with explicit `targetTLI: "4"` to bypass timeline fork errors.
> - Separate `serverName` and path for post-recovery backups.
> - Only `recovery` bootstrap (no `initdb`).

To find the correct targetTLI for a given backup:
```bash
kubectl exec -it database-cnpg-1 -n mastodon -c postgres -- \
  barman-cloud-backup-show s3://mastovault/cnpg/mastodon-database database-cnpg <backup_id> | grep "Timeline"
```

#### Step 4: Apply and Monitor Recovery
```bash
kubectl apply -f /path/to/database-cnpg.yaml

kubectl get cluster database-cnpg -n mastodon -w
kubectl get pods -n mastodon -w
kubectl logs -f -n mastodon -l cnpg.io/cluster=database-cnpg -c full-recovery
```

Temporary pod name `database-cnpg-X-full-recovery-XXXX` is **normal**.


#### Step 5: Verify Recovery
```bash
kubectl exec -it database-cnpg-1 -n mastodon -c postgres -- psql -c "SELECT pg_is_in_recovery();"  # Should be f

# Test via pooler with app user
kubectl get secret database-cnpg-app -n mastodon -o jsonpath='{.data.password}' | base64 -d > /tmp/pw
kubectl run test --rm -i --image=postgres:17 -n mastodon -- bash -c \
  "PGPASSWORD=\$(cat) psql -h database-cnpg-pooler-rw -U app -d mastodon_production -c 'SELECT COUNT(*) FROM accounts;'"
rm /tmp/pw

# Final confirmation - cluster should show ready and not in recovery
kubectl get cluster database-cnpg -n mastodon
# Expected: STATUS=Cluster in healthy state, INSTANCES=2/2
```

#### Step 6: Scale Up Applications
```bash
kubectl scale deployment -n mastodon mastodon-web --replicas=2
kubectl scale deployment -n mastodon mastodon-streaming --replicas=2
kubectl scale deployment -n mastodon mastodon-sidekiq-default --replicas=1
kubectl scale deployment -n mastodon mastodon-sidekiq-federation --replicas=1
kubectl scale deployment -n mastodon mastodon-sidekiq-background --replicas=2
kubectl scale deployment -n mastodon mastodon-sidekiq-scheduler --replicas=1
kubectl scale deployment -n mastodon mastodon-onion --replicas=1
```


#### Step 7: Return to Normal Configuration (After 24h stability)
1. Remove the entire `bootstrap` section.
2. Remove the `externalClusters` section.
3. Remove `recoveryTarget` if present.
4. In `plugins`, change `serverName` back to `database-cnpg` and update `barmanObjectName` to `database-backup` (original path).
5. Increase `walStorage.size` back to `20Gi`.
6. Apply the updated manifest.

### Legacy Procedure: Separate Recovery Cluster
**Use only for testing** – requires application config changes.

(Original Option A/B content retained here – omitted for brevity in this combined version, but keep if desired.)

## Verification Procedures
### Pre-Switchover Validation Checklist
(See original checklist – all items validated in successful recovery.)

### Post-Recovery Validation
```bash
kubectl get cluster database-cnpg -n mastodon
kubectl get pods -n mastodon
kubectl logs -n mastodon deployment/mastodon-web | grep -i error
```

### Quick Health Check Script
(See original script – update cluster name to `database-cnpg`.)

## Troubleshooting
### Common Issues
- **Timeline mismatch** (`requested timeline is not a child`): Use PITR with correct `targetTLI`.
- **WAL archive check failed**: Ensure different `serverName` for post-recovery archiving.
- **PVC provisioning stuck**: Full cleanup required (including force delete).
- **Recovery stuck**: Check logs of `-full-recovery` container.

### References
- CloudNativePG Documentation: https://cloudnative-pg.io/documentation/current/backup_recovery/
- Barman Cloud Plugin: https://cloudnative-pg.io/plugin-barman-cloud/docs/