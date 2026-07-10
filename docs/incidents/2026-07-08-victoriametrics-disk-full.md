# VictoriaMetrics Disk Full / Read-Only Mode (July 2026)

Found during a cost-cut audit: `vmsingle-vm`'s 20Gi PVC was at 100% and VictoriaMetrics had been silently dropping all incoming writes for an unknown period (`the storage is in read-only mode; check -storage.minFreeDiskSpaceBytes command-line flag value`). No historical Prometheus data existed to diagnose the prior trend because of this — the outage was self-masking.

## Root cause

Cardinality, not retention or genuine growth. Once writes were unblocked, `/api/v1/status/tsdb` showed **175,275 total series**, with `apiserver_*` and `etcd_request_duration_seconds_bucket` histogram metrics — the default Kubernetes control-plane scrape job — accounting for **~75,500 series (43% of the total)**:

| Metric | Series |
|---|---|
| `apiserver_request_duration_seconds_bucket` | 23,976 |
| `apiserver_request_sli_duration_seconds_bucket` | 16,654 |
| `etcd_request_duration_seconds_bucket` | 16,032 |
| `apiserver_request_body_size_bytes_bucket` | 9,792 |
| `apiserver_response_sizes_bucket` | 3,680 |
| `apiserver_watch_cache_read_wait_seconds_bucket` | 2,534 |
| `apiserver_watch_events_sizes_bucket` | 1,665 |

These histograms multiply out across `le` (bucket) × `verb` × `resource` × `scope` × `version` × `group` — a well-known default-config cardinality trap for any Prometheus/VictoriaMetrics setup that scrapes the apiserver without relabeling. Not specific to this cluster's workload.

## Fix applied

1. Temporarily expanded `vmsingle-vm` PVC 20Gi → 25Gi (`kubectl patch pvc` + pod restart to complete the CSI filesystem resize) to unstick writes and let the buffered vmagent backlog drain — Hetzner CSI only supports growing, not shrinking, so this is a real small ongoing cost (~€0.29/mo for the extra 5Gi), not reverted.
2. Added an `inlineRelabelConfig` drop rule to the `vmagent` VMAgent CR / `kubernetes/apps/base-system/victoriametrics/helm-values.yaml`, dropping `_bucket` series for the 7 metrics above while keeping `_sum`/`_count` (so average latency is still queryable, only per-bucket percentiles are lost).
3. Verified live: disk usage stabilized at 80% (20.0G/24.9G) after the backlog drained and compaction ran; no further `read-only mode` warnings.

## Verification

```bash
kubectl logs -n victoriametrics <vmsingle-pod> --since=5m | grep -i read-only   # should be empty
kubectl exec -n victoriametrics <vmsingle-pod> -- df -h /victoria-metrics-data
kubectl exec -n victoriametrics <vmsingle-pod> -- wget -qO- 'http://127.0.0.1:8428/api/v1/status/tsdb?topN=15'
```

## Action items

- [ ] Re-check `totalSeries` and disk usage after a few days once the old high-cardinality series fully roll out of the 14-day retention window — expect further headroom to open up (may allow reverting the 25Gi bump back toward 20Gi, or just leaves margin).
- [ ] Consider alerting on `vm_free_disk_space_bytes` below a threshold so this doesn't silently recur — this incident had no alert and was only found via a manual `kubectl logs` check.
- [ ] `hcloud-exporter` pod in this namespace is separately crash-looping (730+ restarts) — unrelated to this incident, not yet investigated.
