# CNPG Migration - Manual Steps

## Pre-Cutover Checklist (Run by Operator)

1. **Verify the ExternalSecret is syncing the standby credentials:**
   ```bash
   kubectl get externalsecret zalando-standby-credentials -n mastodon
   kubectl get secret zalando-standby-credentials -n mastodon
   ```
   The ExternalSecret automatically pulls credentials from the Zalando operator's generated secret.

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
   NEW_USER=$(kubectl get secret database-cnpg-app -n mastodon -o jsonpath='{.data.username}' | base64 -d)
   NEW_PASS=$(kubectl get secret database-cnpg-app -n mastodon -o jsonpath='{.data.password}' | base64 -d)
   echo "Username: $NEW_USER"
   echo "Password: $NEW_PASS"
   ```

5. **Update the Mastodon database credentials secret (preserving the existing key structure):**
   ```bash
   kubectl create secret generic mastodon-db-url -n mastodon \
     --from-literal=DB_USER="$NEW_USER" \
     --from-literal=DB_PASS="$NEW_PASS" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
   **Note:** This preserves the `DB_USER` and `DB_PASS` keys that Mastodon deployments expect via `envFrom`.

6. **Update the database host configuration:**
   Update `kubernetes/apps/platform/mastodon/configs/mastodon-database.env` to point to the new pooler:
   ```bash
   sed -i 's/DB_HOST=.*/DB_HOST=database-cnpg-pooler-rw.mastodon.svc.cluster.local/' \
     kubernetes/apps/platform/mastodon/configs/mastodon-database.env
   ```
   Commit and push this change, or manually patch the ConfigMap:
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

2. **Replace the replica manifest with the promoted one:**
   ```bash
   mv kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg-promoted.yaml \
     kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml
   ```
   **Note:** The promoted manifest now includes all Pooler resources to prevent service disruption.

3. **Remove the external cluster configuration (optional cleanup):**
   Edit `kubernetes/apps/platform/mastodon/resources/workloads/database-cnpg.yaml` and remove:
   - The `bootstrap.pg_basebackup` section
   - The `replica` section  
   - The `externalClusters` section
   
   This is optional as these sections are ignored once the cluster is promoted.

4. **Commit and push the changes:**
   ```bash
   git add kubernetes/apps/platform/mastodon/
   git commit -m "chore: complete CNPG migration, remove Zalando operator"
   git push
   ```

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
