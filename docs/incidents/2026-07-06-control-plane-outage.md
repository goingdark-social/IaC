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

## Action Items (durable, beyond the immediate fix)

- [ ] Add a Renovate rule to require manual merge for major-version bumps of `hcloud-k8s/kubernetes/hcloud` (and other Terraform modules under `opentofu/`).
- [ ] Remove the redundant `talos_extra_remote_manifests` gateway-api entry; rely solely on the module's built-in gateway-api CRD management.
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
