# Shrinking CNPG Postgres storage (Mastodon, Stalwart mail)

CNPG applies `storage.size` / `walStorage.size` uniformly across every instance in a `Cluster`, and the validating webhook rejects any decrease to those values by default. There's no way to just `kubectl patch` the size down.

**CNPG has a native, in-place rolling-shrink procedure for this** (confirmed against the official docs, https://cloudnative-pg.io/docs/1.29/storage/ — "Reducing the size of the persistent volumes"). It stays on the *same* `Cluster` object, so unlike a cross-cluster cutover it needs **no app downtime, no Pooler repointing, and no duplicate `ScheduledBackup`/`ObjectStore` resources** — those all still point at the same cluster name throughout. This is the preferred approach; use the cutover procedure at the bottom only if this one is somehow blocked.

`kubectl-cnpg` plugin is installed and available (`/usr/local/bin/kubectl-cnpg`), needed for the `destroy`/`promote` steps below.

## Preconditions

- Confirm current data comfortably fits in the new smaller size before starting — if it doesn't, instances recreated on the smaller volume can fail to rejoin or run out of space. Current utilization is well within target on both clusters (see table at bottom), so this is safe.
- `maxSyncReplicas: 0` is set on the Mastodon cluster (confirmed) — no sync replication config to worry about mid-rollout.

### Why the WAL volume can't be shrunk to "just enough for normal writes"

It's tempting to size `walStorage` off of steady-state usage alone, but the WAL volume isn't just a buffer for when S3 archiving is unavailable — it's load-bearing even when archiving is healthy:

- Every commit fsyncs to the **local** WAL segment first; archiving to S3 happens asynchronously afterward. The local volume is the actual durability mechanism, not a fallback.
- The primary retains WAL until every standby's replication slot confirms receipt. If a standby lags or is briefly down — including **during this very rolling-shrink procedure**, since each `destroy`/recreate cycle takes a standby offline while it re-syncs — WAL accumulates on the primary until it catches up.
- `archive_timeout: 5min` (set on both clusters) bounds how long an idle WAL segment can sit unarchived, which keeps steady-state usage low, but it doesn't bound replication-lag buffering during a rollout like this one.

Practical effect: keep an eye on primary disk usage while a standby is being recreated during step 3/6 below (`kubectl exec` into the primary and check `pg_wal` size, or watch the PVC usage), and don't shrink WAL storage down to the bare steady-state minimum — the 10Gi target for Stalwart (from 3% utilization on 30Gi) already has this margin built in and is safe, but don't push it lower without re-checking.

## Native rolling-shrink procedure (per cluster)

Repeat this whole procedure separately for `mastodon/database-cnpg` and `stalwart/stalwart-postgresql` (data + WAL are shrunk together in one pass, since both fields are set at once in step 1).

1. **Disable the validating webhook for this cluster** and set the new size + a spare instance, in one edit:
   ```bash
   kubectl annotate cluster -n <ns> <cluster> cnpg.io/validation=disabled
   kubectl patch cluster -n <ns> <cluster> --type=merge -p '{"spec":{"storage":{"size":"<new-size>"},"walStorage":{"size":"<new-wal-size>"},"instances":<current+1>}}'
   ```
   (Omit `walStorage` if the cluster doesn't set it separately.)

2. **Re-enable validation**:
   ```bash
   kubectl annotate cluster -n <ns> <cluster> cnpg.io/validation-
   ```
   The new smaller size is now in the spec. Existing instances keep their current (larger) volumes — the operator logs an informational `cannot decrease storage requirement` for each until it's recreated. Expected and harmless, not an error.

3. **Destroy one standby** that still has an old-size volume — the operator provisions its replacement (new name, not the destroyed one) on the new smaller volume:
   ```bash
   kubectl cnpg destroy <cluster> <instance-ordinal> -n <ns>
   ```
   Wait for the replacement to become healthy (`kubectl cnpg status -n <ns> <cluster>`) before continuing.

4. **Repeat step 3** for every remaining standby still on an old-size volume.

5. **Promote a newly-created (smaller) standby**, demoting the current primary (which still has an old-size volume) to standby:
   ```bash
   kubectl cnpg promote <cluster> <instance-ordinal> -n <ns>
   ```

6. **Destroy the former primary** (now a standby, old-size volume) so it's recreated on the new smaller volume, and wait for it to become healthy.

7. **Scale `.spec.instances` back down** to the original count.

8. Verify: `kubectl cnpg status -n <ns> <cluster>` shows `Cluster in healthy state`, all instances on the new size, no replication lag. Then confirm app functionality (Mastodon: post/read a status; Stalwart: send/receive a test email) — should need no app-side action since Pooler/service names never changed.

No maintenance window is strictly required (no full outage), but each `destroy`/recreate cycle briefly drops a replica, so treat it like any other rolling maintenance — do it in a normal deploy window and confirm HA is intact (`Cluster in healthy state`, correct instance count) before and after.

## Fallback: new-cluster cutover

Only needed if the native path above is blocked for some reason (e.g. plugin/webhook incompatibility). This is more invasive — full app downtime, Pooler repoint, and duplicate backup config — so it's a fallback, not the default:

Both clusters use the **`barman-cloud.cloudnative-pg.io` plugin** (not the legacy built-in `barmanObjectStore`) — confirmed via `.spec.plugins[]` on each live `Cluster`:

| Cluster | Namespace | Backup plugin config (`ObjectStore` CR) |
|---|---|---|
| `database-cnpg` (Mastodon) | `mastodon` | `barmanObjectName: database-backup` |
| `stalwart-postgresql` | `stalwart` | `barmanObjectName: stalwart-cnpg-backup` |

The new cluster's `bootstrap.recovery` must reference this same plugin/`ObjectStore`, e.g.:

```yaml
spec:
  bootstrap:
    recovery:
      source: <old-cluster-name>
  externalClusters:
    - name: <old-cluster-name>
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: database-backup   # or stalwart-cnpg-backup
```
(Verify exact field names against the installed CNPG/plugin version's CRD — `kubectl explain cluster.spec.externalClusters.plugin` — before running; plugin-based recovery syntax has changed across CNPG minor versions.)

1. Create a second `Cluster` resource (new name, e.g. `<name>-shrunk`) with the desired smaller `storage.size`/`walStorage.size`, bootstrapped per the plugin config above.
2. Let it catch up to the primary (recovery target `latest`), then verify with `kubectl cnpg status -n <ns> <new-cluster>` showing `Cluster in healthy state` and 0 replication lag.
3. **Create matching `ScheduledBackup` and `ObjectStore` resources for the new cluster before cutover, not after** — skipping it silently leaves the database with zero backup coverage post-cutover:
   - Mastodon: new `ScheduledBackup` (copy of `database-backup`, `cluster.name` → new cluster name).
   - Stalwart: new `ScheduledBackup` (copy of `stalwart-postgresql-backup`).
4. Repoint the **Pooler** resources (PgBouncer) at the new cluster — apps connect through these, not the Cluster service directly:
   - `mastodon/database-cnpg-pooler-rw` and `mastodon/database-cnpg-pooler-ro`: `.spec.cluster.name` currently `database-cnpg` → change to new cluster name (or create new poolers and repoint the apps' connection secrets at them).
   - Check for an equivalent Stalwart pooler/service reference the same way (`kubectl get pooler -n stalwart`).
5. Stop writes to the app briefly (scale to 0, or maintenance page). **All of these write to Postgres, not just the web deployment** — pause every one:
   - Mastodon (`mastodon` namespace): `mastodon-web`, `mastodon-streaming`, `mastodon-onion`, `mastodon-sidekiq-background`, `mastodon-sidekiq-default`, `mastodon-sidekiq-federation`, `mastodon-sidekiq-scheduler` — 7 deployments total.
   - Stalwart mail: check `kubectl get deploy -n stalwart` for the actual deployment name(s) at execution time.
6. Confirm the new cluster has caught up to the last transaction, then verify the Pooler(s) are routing to it.
7. Resume the app, verify functionality.
8. Once stable for a day or two: delete the old `Cluster`, its `ScheduledBackup`, and its PVCs/Hetzner volumes. Double check the old `ObjectStore`'s S3 backups aren't needed for retention/compliance before letting them expire.

## Current oversized volumes (not urgent, no disk pressure)

- Mastodon CNPG data: 80Gi × 2 instances, 22% used → target ~30Gi × 2 (~€5.72/mo savings)
- Stalwart Postgres data: 50Gi × 2 instances, ~0% used → target ~15Gi × 2 (~€4.00/mo savings)
- Stalwart Postgres WAL: 30Gi × 2 instances, 3% used → target ~10Gi × 2 (~€2.29/mo savings)
