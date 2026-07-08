# Shrinking CNPG Postgres storage (Mastodon, Stalwart mail)

CNPG applies `storage.size` / `walStorage.size` uniformly across every instance in a `Cluster`, and the CNPG validating webhook rejects any decrease to those values. There is no supported in-place shrink and no supported way to run one instance on a smaller PVC than its siblings within the same `Cluster`. Growing a replica onto a smaller PVC and failing over to it does not work.

The only way to shrink is a new-cluster cutover:

1. Create a second `Cluster` resource (new name, e.g. `<name>-shrunk`) with the desired smaller `storage.size`/`walStorage.size`, bootstrapped from the existing cluster's Barman Cloud backup (`bootstrap.recovery` from the same S3 backup location, or `externalClusters` + streaming replication for a hot standby-then-promote path if a zero-data-loss cutover is required).
2. Let it catch up to the primary (recovery target `latest`, or let streaming replication reach zero lag).
3. Stop writes to the app briefly (scale the app deployment to 0, or use a maintenance page):
   - Mastodon: `kubernetes/apps/platform/mastodon/overlays/prod/patches/resources.yaml` (Cluster at lines 117-126).
   - Stalwart mail: `kubernetes/apps/platform/mail/base/resources/database/cluster.yaml` (lines 5-11).
4. Confirm the new cluster has caught up to the last transaction, then repoint the app's connection secret/service at the new cluster's primary service.
5. Resume the app, verify functionality (Mastodon: post/read a status; Stalwart: send/receive a test email).
6. Once stable for a day or two, delete the old `Cluster` and its PVCs/Hetzner volumes.

This is real production database surgery with a short write-pause window — schedule it deliberately, don't run it ad hoc. Current oversized volumes (not urgent, no disk pressure):

- Mastodon CNPG data: 80Gi × 2 instances, 22% used → target ~30Gi × 2 (~€5.72/mo savings)
- Stalwart Postgres data: 50Gi × 2 instances, ~0% used → target ~15Gi × 2 (~€4.00/mo savings)
- Stalwart Postgres WAL: 30Gi × 2 instances, 3% used → target ~10Gi × 2 (~€2.29/mo savings)
