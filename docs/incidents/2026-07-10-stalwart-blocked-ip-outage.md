# Stalwart Mail: 43-Hour Outage from Auto-Banned Internal IPs (July 2026)

Found via a live "upstream connect error or disconnect/reset before headers, reset reason: connection termination" from the gateway fronting `mailadmin.peekoff.com`. All 3 `stalwart-N` pods were `0/1 Running`, restarting every ~5 minutes continuously since **2026-07-08 ~08:32 UTC** (the v0.15.5 → v0.16.9 migration) — roughly 43 hours before being caught.

## Root cause

During the v0.16 migration, Stalwart's brute-force/ban protection permanently blocked (`expiresAt: null`) several internal cluster IPs that hit the server before the post-migration allowlist step was completed:

- `10.0.133.92`, `10.0.129.66`, `10.0.129.74` — kubelet probe-source IPs (one per node hosting a replica)

Once banned, kubelet's own `startupProbe` (`GET /healthz/ready`) was rejected by Stalwart as coming from a banned IP → probe failed → kubelet killed the container → repeat forever. Pods never went `Ready`, so the Service had zero healthy endpoints, producing the gateway's "no healthy upstream" error externally.

Two real external IPs (`94.234.95.25`, `66.132.172.32`) were also blocked in the same list — correctly, unrelated to this incident, left alone.

**Why this wasn't visible/fixable via git/kustomize**: in v0.15.5, `allowed-ip`/`blocked-ip` and proxy trusted-networks lived in `config.toml` (`[server.security] allowed-ip = [...]`). In v0.16, `config.json` is intentionally minimal — just the one-time Postgres DataStore bootstrap. Everything else (listeners, proxy trusted-networks, the IP allow/block lists) moved to JMAP-managed objects stored in Postgres itself. Nothing in `kubernetes/apps/platform/mail/` can express or prevent this — it's live database state, not GitOps-managed config.

## Fix applied

1. Temporarily set `STALWART_RECOVERY_ADMIN=admin:<random>` on the `stalwart` StatefulSet (env var) — a documented, non-destructive backdoor credential that works live without `STALWART_RECOVERY_MODE=1` and without taking the DB into recovery/wipe mode.
2. Used it to call Stalwart's undocumented management JMAP methods (found by pulling `stalwartlabs/stalwart` and `stalwartlabs/webui` source directly, since the public docs example for this was wrong): all custom/enterprise object types are namespaced with an `x:` prefix, e.g. `x:BlockedIp/query`, `x:BlockedIp/set`, `x:AllowedIp/set`, under the `urn:stalwart:jmap` JMAP capability.
3. Listed blocked IPs (`x:BlockedIp/query` + `x:BlockedIp/get`), destroyed only the 3 internal ones (`x:BlockedIp/set` with `destroy`), left the 2 external attacker IPs banned.
4. Added a permanent allowlist entry so this can't recur: `x:AllowedIp/set create` → `{"address": "10.0.0.0/16", "reason": "Internal cluster network (kubelet probes, pod-to-pod, Hetzner LB) - never auto-ban"}`. A narrower `10.0.95.0/24` entry (Hetzner LB subnet) already existed from the original migration.
5. Removed `STALWART_RECOVERY_ADMIN` from the StatefulSet again immediately after use (must never stay set on a production deployment, per Stalwart's own docs).

## Verification

```bash
kubectl get pods -n stalwart -l app.kubernetes.io/name=stalwart   # all 3 should be 1/1 Ready
kubectl get statefulset -n stalwart stalwart -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'
# should NOT include STALWART_RECOVERY_ADMIN
```

## How to unblock/allowlist an IP if this recurs (no recovery pod needed)

```bash
# 1. Temporarily grant a recovery admin session (works live, no wipe risk):
kubectl set env statefulset/stalwart -n stalwart STALWART_RECOVERY_ADMIN="admin:$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

# 2. Wait for a pod to restart and pick up the env var (they restart every ~5min anyway if crash-looping),
#    then from inside that pod, call the loopback JMAP API (bypasses IP bans — localhost isn't banned):
kubectl exec -n stalwart <pod> -- sh -c '
  PW=$(printenv STALWART_RECOVERY_ADMIN | cut -d: -f2)
  curl -s -H "Host: mail.peekoff.com" -u "admin:${PW}" -H "Content-Type: application/json" \
    -d "{\"methodCalls\":[[\"x:BlockedIp/query\",{\"accountId\":\"<admin-account-id>\"},\"c1\"]],\"using\":[\"urn:ietf:params:jmap:core\",\"urn:stalwart:jmap\"]}" \
    http://127.0.0.1:8080/jmap/
'
# get the admin accountId from GET /jmap/session (same auth) if unknown.

# 3. x:BlockedIp/set {"destroy": ["<id>", ...]} to unban, x:AllowedIp/set {"create": {...}} to permanently allow.

# 4. Remove the env var again:
kubectl set env statefulset/stalwart -n stalwart STALWART_RECOVERY_ADMIN-
```

## Action items

- [ ] Consider alerting on `stalwart` StatefulSet pods being `NotReady` for >10 minutes — this incident ran 43 hours with no alert, only caught via a user-reported gateway error.
- [ ] After any future Stalwart recovery-mode session or migration, explicitly re-check `x:BlockedIp/query` and `x:AllowedIp/query` before considering the migration done — this is the step that was skipped on 2026-07-08.
- [x] `10.0.0.0/16` allowlisted permanently (this incident).
- [ ] `ArgoCD`'s `application-controller` is still scaled to `0` and `platform-mail` still targets `main` (branch with the earlier ConfigMap/CRD fixes not yet merged) — unrelated to this incident's root cause, but still open from the v0.16 migration work.
