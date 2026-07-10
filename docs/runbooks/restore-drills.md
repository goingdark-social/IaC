# Restore drill cleanup

Manual restore/verification drills (e.g. `stalwart-restore-test`, `stalwart-restore-verify` namespaces) create scratch PVCs. The default StorageClass (`hcloud-volumes-encrypted-xfs`) uses `reclaimPolicy: Retain`, so deleting the namespace leaves the PV and the underlying Hetzner volume behind, still billed.

Use the scratch StorageClass instead:

```
storageClassName: hcloud-volumes-encrypted-xfs-scratch
```

It's identical (encrypted XFS) but `reclaimPolicy: Delete`, so tearing down the namespace also deletes the PV and the Hetzner volume — no manual cleanup needed.

If a drill already used the default StorageClass, clean up manually after:

```
kubectl get pv | grep <namespace>
kubectl delete pv <pv-name>          # only after status is Released
hcloud volume delete <volume-id>     # volumeHandle from `kubectl get pv <pv-name> -o jsonpath='{.spec.csi.volumeHandle}'`
```
