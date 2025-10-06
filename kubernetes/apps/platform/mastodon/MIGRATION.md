# CNPG Migration - Manual Steps

## Pre-Cutover Checklist (Run by Operator)

1. **Extract Zalando standby password and replace the placeholder:**
   ```bash
   kubectl get secret mastodon-postgresql.standby.credentials -n mastodon \
     -o jsonpath='{.data.password}' | base64 -d
   ```
   Edit the `zalando-standby-credentials` secret in `database-cnpg.yaml` and replace `REPLACE_WITH_ZALANDO_STANDBY_PASSWORD` with the decoded value before applying the manifest.

2. **Verify CNPG cluster is replicating:**
   ```bash
   kubectl cnpg status database-cnpg -n mastodon
   kubectl get pods -n mastodon -l cnpg.io/cluster=database-cnpg
   ```

3. **Monitor replication lag:**
   ```bash
   kubectl cnpg psql database-cnpg -n mastodon -- \
     -c "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());"
   ```
   The result should be less than 1KB before the cutover window starts.

## Cutover Steps (Planned Maintenance Window)

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

2. **Wait for replication lag to reach 0 bytes.**

3. **Promote the CNPG cluster:**
   ```bash
   kubectl apply -f kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml
   ```

4. **Fetch the new application credentials:**
   ```bash
   kubectl get secret database-cnpg-app -n mastodon \
     -o jsonpath='{.data.password}' | base64 -d
   ```

5. **Update the Mastodon database URL secret:**
   ```bash
   kubectl create secret generic mastodon-db-url -n mastodon \
     --from-literal=DATABASE_URL="postgresql://mastodon:<password>@database-cnpg-pooler-rw.mastodon.svc.cluster.local:5432/mastodon?sslmode=verify-ca" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

6. **Update the ConfigMap with the new host:**
   ```bash
   kubectl patch configmap mastodon-database -n mastodon --type merge -p '{
     "data":{
      "DB_HOST":"database-cnpg-pooler-rw.mastodon.svc.cluster.local",
      "DB_PORT":"5432"
    }
  }'
   ```

7. **Refresh the collation version:**
   ```bash
   kubectl cnpg psql database-cnpg -n mastodon -- \
     -c "ALTER DATABASE mastodon REFRESH COLLATION VERSION;"
   ```

8. **Bring the Mastodon workloads back online:**
   ```bash
   kubectl scale deployment -n mastodon \
     mastodon-web --replicas=1 \
     mastodon-streaming --replicas=1 \
     mastodon-sidekiq-default --replicas=1 \
     mastodon-sidekiq-federation --replicas=1 \
     mastodon-sidekiq-background --replicas=1 \
     mastodon-sidekiq-scheduler --replicas=1
   ```

9. **Confirm the application is healthy:**
   ```bash
   kubectl get pods -n mastodon
   kubectl logs -n mastodon -l app=mastodon-web --tail=50
   ```

## Post-Cutover (After 48 Hours of Stable Operation)

1. **Remove the Zalando manifest from Git:**
   Edit `kubernetes/apps/platform/mastodon/resources/workloads/kustomization.yaml` and delete the `- database.yaml` entry.

2. **Replace the replica manifest:**
   ```bash
   mv kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml \
     kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
   ```

3. **Optionally scale down the Zalando operator:**
   ```bash
   kubectl scale deployment zalando-postgres-operator -n postgres-operator --replicas=0
   ```
