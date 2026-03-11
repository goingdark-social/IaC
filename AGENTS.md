goingdark.social infrastructure repository for Hetzner Cloud and Talos Linux with OpenTofu provisioning and Kubernetes GitOps delivery through ArgoCD.

<Global_rules>
- Scope every change to the user request and touched components.
- Preserve existing naming, directory, and architecture patterns in edited files.
- Keep secrets out of tracked files and use variable or ExternalSecret inputs.
- Reuse existing variables, modules, and resource objects before creating new ones.
- Keep one Kubernetes resource per file outside strategic patch files.
- Keep container image references pinned to explicit versions.
- Keep procedural runbooks, TODO lists, and troubleshooting flows in skills.
- Do not create any files the user did not ask for 
- Never create markdown documents (summaries, findings, analyses, or reports) unless the user explicitly asks for that deliverable.
</Global_rules>

<kubernetes>
Kubernetes configuration lives under kubernetes/ and deploys through ArgoCD with Kustomize.
<kubernetes_rules>
- Use Kustomize application roots as Kubernetes apply targets.
- Avoid direct apply commands against base/ directories and resource subdirectories.
- Use ExternalSecret resources with ClusterSecretStore bitwarden-backend for secret sync.
- Use Gateway resources for listener and TLS configuration.
- Use HTTPRoute for application routing.
- Use default deny network posture with explicit allow rules.
- Use subdirectory references in kustomization files instead of long per-file lists.
- do not use helm directly. that is achieved with kustomize helmcharts.
- Keep Mastodon resources grouped under workloads/, autoscaling/, networking/, monitoring/, secrets/, storage/, jobs/, and disruption/.
- Keep VPA resources in recommender-only mode with updater and admission disabled.
</kubernetes_rules>
</kubernetes>

<opentofu>
OpenTofu configuration lives under opentofu/ and manages Hetzner and Talos infrastructure state.
<opentofu_rules>
- Run tofu commands from the opentofu/ directory.
- Read variables before adding new OpenTofu variables.
- Use provider source hcloud-k8s/kubernetes/hcloud for Hetzner blocks.
- Use provider source cloudflare/cloudflare for Cloudflare blocks.
- Use provider source hashicorp/kubernetes for Kubernetes blocks in OpenTofu.
- Reference managed resources through resource attributes and module outputs.
- Avoid data source lookups for resources created in the same OpenTofu state.
- Pass secret and token values through var.* inputs.
</opentofu_rules>
</opentofu>

<mail>
Mail platform configuration lives under kubernetes/apps/platform/mail/ with split ingress between Cloudflare Tunnel and Hetzner LoadBalancer.
<mail_rules>
- Route mail web UI traffic through Cloudflare Tunnel and Gateway API.
- Route SMTP and IMAP family traffic through a Kubernetes LoadBalancer Service managed by hcloud-cloud-controller-manager.
- mail LoadBalancer listener ports set to 25, 465, 587, 993, and 4190.
- mail LoadBalancer listener ports 110, 995, 143, 80, and 443 excluded.
- Use CiliumNetworkPolicy v2 resources for mail network policy behavior.
- Allow Cilium world identity ingress on ports 25, 465, 587, 993, and 4190.
- Allow Cilium ingress identity ingress on port 8080.
- Use StatefulSet volumeClaimTemplates for mail persistent storage.
- Use storage class hcloud-volumes-encrypted-xfs for mail stateful volumes.
- Use Cloudflare R2 regional endpoint format https://<account_id>.eu.r2.cloudflarestorage.com for backups.
- Keep non-regional Cloudflare R2 endpoint format absent from backup settings.
- Restart CNPG cluster with kubectl cnpg restart -n stalwart stalwart-postgresql.
- Keep kubectl rollout restart absent from CNPG restart operations.
- Keep direct CNPG pod deletion absent from CNPG restart operations.
- Point DNS record mail.peekoff.com to the stalwart-mail LoadBalancer external IP.
- Keep SMTP and IMAP mail domain records in Cloudflare DNS-only mode.
</mail_rules>
</mail>
