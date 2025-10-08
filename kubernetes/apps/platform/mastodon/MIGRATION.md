# CNPG Migration - Quick Reference

> **Note**: This is a quick reference guide. For comprehensive migration documentation using pg_dump/pg_restore, see [MIGRATION-PGDUMP.md](./MIGRATION-PGDUMP.md).

## Migration Approach

This migration uses CloudNativePG's `bootstrap.initdb.import` feature with pg_dump/pg_restore for a safe, logical backup-based migration. The process has two phases:

1. **Phase 1 (Zero Downtime)**: Initial import while production continues on Zalando cluster
2. **Phase 2 (Short Maintenance)**: Final cutover to CloudNativePG cluster

## Pre-Cutover Checklist (Run by Operator)

1. **Verify the ExternalSecret is syncing the standby credentials:**
   ```bash
   kubectl get externalsecret zalando-standby-credentials -n mastodon
   kubectl get secret zalando-standby-credentials -n mastodon
   ```
   The ExternalSecret automatically pulls credentials from the Zalando operator's generated secret.

2. **Deploy CNPG cluster and monitor import:**
   ```bash
   # Apply the configuration
   kubectl apply -f kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
   
   # Monitor import progress
   kubectl logs -n mastodon -l cnpg.io/cluster=database-cnpg -f
   
   # Check cluster status
   kubectl cnpg status database-cnpg -n mastodon
   ```

3. **Verify import completed successfully:**
   ```bash
   # Check table counts match source
   kubectl cnpg psql database-cnpg -n mastodon -- -c "
     SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';
   "
   
   # Compare with Zalando cluster
   kubectl exec -n mastodon mastodon-postgresql-0 -- \
     psql -U postgres mastodon -c "
       SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';
     "
   ```

## Cutover Steps (Planned Maintenance Window)

> **Important**: See [MIGRATION-PGDUMP.md](./MIGRATION-PGDUMP.md) for detailed cutover procedures, verification steps, and troubleshooting.

### Quick Cutover Checklist

1. **Scale down all Mastodon workloads:**
   ```bash
   kubectl scale deployment -n mastodon \
     mastodon-web \
     mastodon-streaming \
     mastodon-sidekiq-default \
     mastodon-sidekiq-federation \
     mastodon-sidekiq-background \
     mastodon-sidekiq-scheduler \
     --replicas=0
   ```

2. **Apply promoted configuration:**
   ```bash
   kubectl apply -f kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml
   ```

3. **Get new database credentials:**
   ```bash
   NEW_USER=$(kubectl get secret database-cnpg-app -n mastodon -o jsonpath='{.data.username}' | base64 -d)
   NEW_PASS=$(kubectl get secret database-cnpg-app -n mastodon -o jsonpath='{.data.password}' | base64 -d)
   echo "User: $NEW_USER"
   echo "Pass: $NEW_PASS"
   ```

4. **Update database credentials (preserving key structure):**
   ```bash
   kubectl create secret generic mastodon-db-url -n mastodon \
     --from-literal=DB_USER="$NEW_USER" \
     --from-literal=DB_PASS="$NEW_PASS" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

5. **Update database host:**
   ```bash
   kubectl patch configmap mastodon-database -n mastodon --type merge -p '{
     "data": {
       "DB_HOST": "database-cnpg-pooler-rw.mastodon.svc.cluster.local",
       "DB_PORT": "5432"
     }
   }'
   ```

6. **Refresh collation version:**
   ```bash
   kubectl cnpg psql database-cnpg -n mastodon -- \
     -c "ALTER DATABASE mastodon REFRESH COLLATION VERSION;"
   ```

7. **Scale up workloads:**
   ```bash
   kubectl scale deployment -n mastodon \
     mastodon-web --replicas=1 \
     mastodon-streaming --replicas=1 \
     mastodon-sidekiq-default --replicas=1 \
     mastodon-sidekiq-federation --replicas=1 \
     mastodon-sidekiq-background --replicas=1 \
     mastodon-sidekiq-scheduler --replicas=1
   ```

8. **Verify application health:**
   ```bash
   kubectl get pods -n mastodon
   kubectl logs -n mastodon -l app=mastodon-web --tail=50
   ```

## Post-Cutover (After 24-48 Hours of Stable Operation)

> **Detailed cleanup procedures**: See [MIGRATION-PGDUMP.md](./MIGRATION-PGDUMP.md#post-migration-after-24-48-hours-stable-operation)

1. **Verify backups are working:**
   ```bash
   kubectl get schedulebackup -n mastodon
   kubectl cnpg backup database-cnpg -n mastodon  # Trigger manual backup
   ```

2. **Remove Zalando resources from kustomization:**
   ```bash
   # Edit kubernetes/apps/platform/mastodon/resources/workloads/kustomization.yaml
   # Remove the '- database.yaml' line
   
   # Move promoted config to primary
   mv kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml \
      kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
   ```

3. **Archive Zalando cluster (keep for 7 days as safety net):**
   ```bash
   kubectl patch postgresql mastodon-postgresql -n mastodon \
     --type merge \
     -p '{"spec":{"numberOfInstances":0}}'
   ```

4. **After 7 days, remove Zalando cluster completely:**
   ```bash
   kubectl delete postgresql mastodon-postgresql -n mastodon
   ```

5. **Commit and push changes:**
   ```bash
   git add kubernetes/apps/platform/mastodon/
   git commit -m "chore: complete CNPG migration, remove Zalando operator"
   git push
   ```

## Rollback Procedure

If issues occur during cutover:

```bash
# 1. Scale down CNPG-connected workloads
kubectl scale deployment -n mastodon mastodon-web mastodon-streaming mastodon-sidekiq-* --replicas=0

# 2. Revert database host
kubectl patch configmap mastodon-database -n mastodon --type merge -p '{
  "data": {"DB_HOST": "mastodon-postgresql.mastodon.svc.cluster.local", "DB_PORT": "5432"}
}'

# 3. Restore original credentials (if changed)
# Use backup or recreate with original values

# 4. Scale up with original config
kubectl scale deployment -n mastodon mastodon-web --replicas=2 mastodon-streaming --replicas=2
```

See [MIGRATION-PGDUMP.md](./MIGRATION-PGDUMP.md#rollback-procedure-if-issues-arise) for detailed rollback procedures.

## Support & Troubleshooting

For detailed troubleshooting, monitoring queries, and common issues, see [MIGRATION-PGDUMP.md](./MIGRATION-PGDUMP.md#troubleshooting).

**Quick checks:**
- Import logs: `kubectl logs -n mastodon -l cnpg.io/cluster=database-cnpg --tail=200`
- Cluster status: `kubectl cnpg status database-cnpg -n mastodon`
- Connection test: `kubectl cnpg psql database-cnpg -n mastodon -- -c "SELECT version();"`


5. **Verify ArgoCD syncs the changes without disruption:**
   ```bash
   kubectl get pods -n mastodon -l cnpg.io/cluster=database-cnpg
   kubectl get pooler -n mastodon
   ```

6. **Optionally scale down the Zalando operator:**
   ```bash
   kubectl scale deployment zalando-postgres-operator -n postgres-operator --replicas=0
   ```

7. **Remove the zalando-standby-secret ExternalSecret (no longer needed):**
   ```bash
   rm kubernetes/apps/platform/mastodon/resources/secrets/zalando-standby-secret.yaml
   ```
   Update `kubernetes/apps/platform/mastodon/resources/secrets/kustomization.yaml` to remove the reference.
