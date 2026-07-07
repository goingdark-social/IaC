# Control Plane Outage (July 2026): Firewall Lockout + Wedged Static Pod Controller

This document covers a multi-day outage on `goingdark-control-1` where Mastodon and Stalwart both returned 500 errors, `kubectl`/`talosctl` access was lost, and `tofu init` stopped working. It was actually three separate, loosely-related problems. This is the reference for what happened, why, and how to avoid repeats.

## Timeline / Symptoms

- App-level: Mastodon and Stalwart (mail) both started returning 500 errors. Both share the same Gateway API `Gateway` ("external" in the `gateway` namespace), so a shared-ingress problem was suspected.
- Operator access: `kubectl` and `talosctl` stopped working entirely (`dial tcp 46.62.164.172:6443/:50000: i/o timeout`).
- IaC: `tofu init -upgrade` started failing to resolve provider versions for `hcloud`, `talos`, `helm`, `http`, `tls`, `random`.

## Root Causes

### 1. Firewall lockout (why `kubectl`/`talosctl` stopped working)
The operator moved houses, changing their public egress IP. The Hetzner Cloud Firewall (`hcloud_firewall.this`, built from `var.firewall_api_source` in `opentofu/secret.auto.tfvars`) only allows inbound `6443` (kube API) and `50000` (Talos API) from an explicit IP allowlist. The new IP wasn't in it, so every request timed out (not "connection refused" — a silent drop is the firewall signature, vs. an actual refused/reset connection which means the packet arrived but nothing answered).

**Fix applied:** added the new IP to `firewall_api_source` in `secret.auto.tfvars`, then ran a **targeted** apply so only the firewall resource changed:
```bash
tofu apply -target=module.kubernetes.hcloud_firewall.this[0]
```
Targeted apply was used deliberately to avoid accidentally rolling out an unrelated bundled Talos/Kubernetes version upgrade that had also accumulated in the plan.

### 2. Broken `tofu init` (why IaC changes couldn't be applied at all for ~3 weeks)
Renovate auto-merged a **major** version bump of the `hcloud-k8s/kubernetes/hcloud` module (v3.30.2 → v4.7.0, PR #411). The module's own `required_providers` versions changed with it, but the root `opentofu/kubernetes.tofu`'s `required_providers` block and `.terraform.lock.hcl` were never updated to match — so `tofu init -upgrade` couldn't resolve providers that satisfied both the root config and the child module simultaneously.

**Fix applied:** aligned the root `required_providers` block in `kubernetes.tofu` with the module's actual (v4.7.0) requirements:
```
hcloud = "1.62.0"
talos  = "0.11.0"
helm   = "~> 3.2.0"
http   = "~> 3.6.0"
tls    = "~> 4.3.0"
random = "~> 3.9.0"
```

**Prevention:** Renovate should not be allowed to auto-merge **major** version bumps of this module unmonitored, since a major bump can silently change internal provider requirements. Add a Renovate rule requiring manual review/merge for major updates to `hcloud-k8s/kubernetes/hcloud` (and ideally any Terraform/OpenTofu module in `opentofu/`).

### 3. Wedged static-pod controller (why the app-level 500s / actual apiserver outage happened)
This was the real cause of the Mastodon/Stalwart 500s, and it's independent of the two issues above (those just prevented *diagnosing and fixing* it promptly).

Roughly 60 hours before the investigation (`talosctl service etcd` event log), etcd's container crashed:
```
[Waiting]: Error running Containerd(etcd), going to restart forever: task "etcd" failed: exit code 255 (59h56m27s ago)
```
kubelet's health checks failed at the same moment. This lines up with a Hetzner Cloud `network.change_alias_ips` audit event around the same time — a private-network IP change is a plausible trigger for etcd (which binds specific IPs) to crash.

containerd's restart policy relaunched etcd, and etcd + kubelet both recovered and reported healthy from then on. **However**, the Talos controller responsible for continuously rendering the kube-apiserver / kube-scheduler / kube-controller-manager static pod manifests (from the `apiserverconfigs` resource, which was and still is correct) never recovered — it stopped producing any `k8s.StaticPod` resources at all. `k8s.StaticPodServerController` was left serving an empty manifest set to kubelet, so kube-apiserver was simply never running again (confirmed via `talosctl containers -k` showing no `kube-apiserver` container, and `talosctl get staticpods` / `staticpodstatus` returning empty). Note: the node itself never rebooted (`/proc/uptime` showed ~117 days) — only the container-level services restarted, and one internal Talos controller got permanently wedged in that process. This is an internal controller-runtime deadlock inside Talos's single `machined` process; it does not self-heal without a restart of that process (i.e., a node reboot).

**Fix (safe procedure):**
1. Fix issue #4 below first (the redundant manifest), so the reboot doesn't come back into a crash-looping `k8s.ExtraManifestController`.
2. Reboot `goingdark-control-1` (`talosctl reboot -n 10.0.64.1`). This is safe in this specific situation because kube-apiserver/scheduler/controller-manager are *already* not running — there's nothing live to disrupt — and etcd is healthy and on-disk, so a reboot does not risk etcd quorum/data loss on this single-control-plane-node cluster.
3. After reboot, verify with:
   ```bash
   talosctl --talosconfig ./talosconfig health
   talosctl --talosconfig ./talosconfig containers -k | grep kube-apiserver
   kubectl get nodes
   ```

**Prevention:** there isn't a good IaC-level prevention for a Talos internal controller deadlock — it's an upstream Talos bug class. The practical mitigation is *faster detection*: this class of failure (etcd/kubelet health-check blips followed by silence) should page/alert rather than be discovered days later via user-facing 500s. See monitoring gap below.

### 4. Duplicate/conflicting gateway-api CRD manifest (found in passing, independently broken)
`opentofu/kubernetes.tofu` explicitly adds:
```hcl
talos_extra_remote_manifests = [
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml",
]
```
The `hcloud-k8s/kubernetes/hcloud` module *also* fetches gateway-api CRDs itself by default (currently resolving to v1.4.1 via its own `gateway_api_crds_version` variable). Both get downloaded and merged by Talos's `k8s.ExtraManifestController`, which has been crash-looping continuously (every 30-75s, indefinitely) on:
```
error updating manifests: error converting manifest to JSON: yaml: line 11: did not find expected key
```
This did **not** cause the apiserver outage (that controller is unrelated to static pod rendering), but it's been silently broken this whole time and should be fixed regardless.

**Fix:** remove the explicit `talos_extra_remote_manifests` block for gateway-api from `kubernetes.tofu` (lines ~223-225) and rely on the module's own `gateway_api_crds_enabled`/`gateway_api_crds_version` — do not maintain both.

**Status: deferred, not yet fixed.** See "Resolution" below — this fix turned out to require the full Talos/Kubernetes version upgrade too, so it's being held until that upgrade is deliberately scheduled, since it's cosmetic (log noise) and not what caused the outage.

## Resolution (2026-07-06)

**Stability restored via `talosctl reboot -n 10.0.64.1` alone** — no `tofu apply` was needed or used to fix the actual outage. This rebooted `machined`, which cleared the wedged static-pod-rendering controller; `k8s.StaticPod` resources reappeared immediately, kube-apiserver came back up, and `kubectl get nodes` reported all three nodes `Ready` again.

Before rebooting, a `tofu plan` was run to see what a routine apply would additionally do, given weeks of accumulated drift from the module bump (root cause #2). It revealed the module bump to v4.7.0 had silently changed the *default* `talos_version` (v1.11.6 → v1.12.8) and `kubernetes_version` (v1.33.10 → v1.33.13) inputs — nobody had pinned them explicitly, so a routine apply would have bundled an unplanned full OS + Kubernetes upgrade across every node into the same apply as the firewall/manifest fixes, gated behind a `talosctl health` check that was guaranteed to fail against the already-broken cluster. It also would have created a previously-unapplied `cluster_autoscaler` nodepool as a side effect. All of that was avoided by explicitly pinning `talos_version = "v1.11.6"` / `kubernetes_version = "v1.33.10"` in `kubernetes.tofu` and temporarily commenting out `cluster_autoscaler_nodepools`, to scope any apply down to just the intended changes.

**New finding: the module version and the Talos OS version are no longer independent.** Attempting to apply the gateway-api manifest removal (with the OS pinned to v1.11.6) failed with:
```
rpc error: code = InvalidArgument desc = "LinkConfig" "v1alpha1": not registered
```
Module v4.7.0 unconditionally generates a `LinkConfig` machine-config document (for network interface setup) that Talos v1.11.6 doesn't recognize. In other words, **module v4.7.0 requires a newer Talos OS version to apply *any* machine configuration change**, not just the manifest fix — the two are now coupled. The apply failed atomically before touching the node, so the cluster was left healthy and untouched.

Practical consequence: the redundant-manifest cleanup (root cause #4) can't be applied in isolation anymore. It'll be done together with the deliberate Talos v1.12.8 / Kubernetes v1.33.13 upgrade, once the cluster has been stable for a while and that upgrade is planned on its own (not as a byproduct of a routine apply).

## Action Items (durable, beyond the immediate fix)

- [ ] Add a Renovate rule to require manual merge for major-version bumps of `hcloud-k8s/kubernetes/hcloud` (and other Terraform modules under `opentofu/`), including a check for whether the bump silently changes default `talos_version`/`kubernetes_version`/other floating defaults.
- [ ] Remove the redundant `talos_extra_remote_manifests` gateway-api entry; rely solely on the module's built-in gateway-api CRD management. Do this as part of the next deliberate Talos/Kubernetes upgrade, not before (see Resolution above — it can no longer be applied in isolation).
- [ ] Always pin `talos_version` and `kubernetes_version` explicitly in `kubernetes.tofu` going forward, rather than letting them float to the module's defaults — a module bump should never silently schedule an OS/Kubernetes upgrade.
- [ ] Add alerting on Talos/Kubernetes control-plane health independent of the cluster itself (e.g. an external blackbox check hitting `:6443` and a Hetzner-side notification on firewall/network changes), so a wedged control plane is caught in minutes, not days.
- [ ] Periodically confirm `firewall_api_source` reflects current expected source IPs (or consider a more dynamic mechanism) since a home IP change silently locks out cluster access with no alert.
- [ ] After any Hetzner-side network event (`network.change_alias_ips` or similar in the audit log), proactively check `talosctl health` and `talosctl containers -k` for the control plane rather than waiting for user-facing symptoms.

## Diagnostic Commands Used (for next time)

```bash
# Confirm firewall vs. service-down (timeout = firewall silently dropping; refused = firewall open, nothing listening)
curl -4 ifconfig.me   # confirm current egress IP matches firewall_api_source

# Talos control-plane health
talosctl --talosconfig ./talosconfig health
talosctl --talosconfig ./talosconfig services
talosctl --talosconfig ./talosconfig containers -k | grep -i apiserver
talosctl --talosconfig ./talosconfig get staticpods
talosctl --talosconfig ./talosconfig get staticpodstatus
talosctl --talosconfig ./talosconfig get apiserverconfigs -o yaml

# Controller-runtime crash loops / errors
talosctl --talosconfig ./talosconfig logs controller-runtime | grep -i error

# Service restart history (look for simultaneous etcd/kubelet failures)
talosctl --talosconfig ./talosconfig service etcd
talosctl --talosconfig ./talosconfig service kubelet
```
