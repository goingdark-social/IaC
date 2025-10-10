How to generate Tor hidden-service keys (one-shot Job)

This creates a one-shot Kubernetes Job that mounts the `mastodon-onion` PVC, starts Tor once to generate the hidden-service files, then exits.

Steps

1. Apply the job manifest:

```bash
kubectl apply -f kubernetes/apps/platform/mastodon/resources/jobs/generate-onion-keys-job.yaml
```

2. Wait for the Job to complete (or check pod logs):

```bash
kubectl -n mastodon get jobs mastodon-onion-keygen
kubectl -n mastodon logs job/mastodon-onion-keygen
```

3. Find the pod that wrote the files (the Job pod). Extract files from the PVC by creating a temporary busybox pod that mounts the same PVC, or copy directly from the Job pod if it still exists.

Example (copy files from PVC via busybox):

```bash
# create a temporary pod that mounts the PVC
kubectl -n mastodon run -i --tty onion-copy --image=busybox --restart=Never -- /bin/sh
# inside the pod shell
mkdir -p /tmp/hs
cp /var/lib/tor/hidden_service/* /tmp/hs/
ls -la /tmp/hs
# then outside the pod, copy files to local machine
kubectl -n mastodon cp onion-copy:/tmp/hs/ ./hs
kubectl -n mastodon delete pod onion-copy

Note: the Job manifest is configured to keep completed pods for 24 hours (ttlSecondsAfterFinished: 86400). If the Job pod still exists you can copy files directly from it without creating a busybox helper:

```bash
# find the Job pod
kubectl -n mastodon get pods -l job-name=mastodon-onion-keygen
# copy files from the job pod (replace POD with the pod name)
kubectl -n mastodon cp POD:/var/lib/tor/hidden_service ./hs
```

If the Job pod has already been removed and you still have the PVC, use the busybox method above to mount the PVC and extract the files.
```

4. The `hs` directory on your machine should contain:

- `hostname` (the .onion hostname)
- `hs_ed25519_public_key`
- `hs_ed25519_secret_key`

5. Create a single Bitwarden secret named `app-mastodon-onion-key` with JSON like:

```json
{
  "hostname": "exampleabcdefg.onion",
  "hs_ed25519_public_key": "-----BEGIN ... PUBLIC KEY ...",
  "hs_ed25519_secret_key": "-----BEGIN ... PRIVATE KEY ..."
}
```

6. After you create the Bitwarden secret, ESO will (within its refreshInterval) create the `mastodon-onion-key` Kubernetes Secret. You can then delete the Job and the generated files are preserved in the PVC and used by the initContainer in the `mastodon-onion` Deployment.

Notes
- This Job writes keys to the PVC. If you re-run the Job on an empty PVC it will create new keys. Only run it once and then back up the keys in Bitwarden.
- The Job uses the Tor image to generate correct v3 keys. You can inspect logs to confirm.
