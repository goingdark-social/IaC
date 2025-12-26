# AGENTS.md

This file provides guidance when working with code in this repository.

## Repository Overview

This is the complete infrastructure-as-code repository for goingdark.social, a Kubernetes-based platform running on Hetzner Cloud. It contains both infrastructure provisioning (OpenTofu) and application deployments (Kubernetes manifests) following GitOps principles with ArgoCD.

**Tech Stack**: Hetzner Cloud, OpenTofu, Talos Linux, Kubernetes, ArgoCD, Cilium, VictoriaMetrics, Gateway API

## Architecture

### Infrastructure Layer (`opentofu/`)
- **kubernetes.tofu** - Talos Linux cluster provisioning on Hetzner Cloud using hcloud-k8s module (v3.2.0)
- **Node pools**: control-plane (cx22, 1 node), worker (cx32, 1 node), autoscaler (cx32, 0-2 nodes with NoSchedule taint)
- **Cluster Autoscaler**: Conservative scaling (10m delay after add/delete, 8m unneeded time, least-waste expander)
- **Storage**: Hetzner CSI with encrypted XFS volumes (nrext64 flag), Retain reclaim policy
- **Networking**: Cilium with WireGuard encryption, public IPv4 enabled
- **Firewall**: API access restricted to configured IPs, allows Cloudflare tunnel (UDP 8443), established UDP responses (32768-65535), and mail ports (TCP 25, 587, 465, 143, 993, 110, 995)
- **Backups**: Hourly etcd backups to S3, CSI encryption with LUKS passphrase
- **Gateway API**: v1.3.0 manifests loaded via talos_extra_remote_manifests
- Generates `talosconfig` and `kubeconfig` for cluster access

### Application Layer (`kubernetes/`)
The repository follows a GitOps pattern with two main ApplicationSets:

#### Infrastructure Apps (`apps/argocd/`, `apps/base-system/`, `apps/database/`)
- **ArgoCD** - GitOps deployment controller
- **Cilium** - eBPF-based networking with encryption and load balancing
- **cert-manager** - TLS certificate management (Cloudflare DNS-01)
- **Gateway API** - Modern ingress management
- **VictoriaMetrics** - Monitoring stack with Grafana and Prometheus adapter
- **VictoriaLogs** - Log aggregation
- **External Secrets** - Integration with Bitwarden for secret management
- **CloudNative-PG** - PostgreSQL operator (Zalando postgres-operator v1.14.0) for database management
- **VPA** - Vertical Pod Autoscaler (recommender mode only, updater/admission disabled)
- **Descheduler** - Workload rebalancing
- **Metrics Server** - Resource metrics API

#### Platform Apps (`apps/platform/`)
- **Mastodon** - Main social platform with custom 1000-character posts
  - Web servers (ghcr.io/glitch-soc/mastodon:v4.5.0, tag set via the root Kustomize images block, 2-4 replicas with HPA)
  - Sidekiq workers: default (1-3 replicas), federation (1-3 replicas), background (1 replica), scheduler (1 replica)
  - Streaming API (ghcr.io/glitch-soc/mastodon-streaming:v4.5.0, tag managed in the same images block, 1-3 replicas with HPA)
  - PostgreSQL cluster (CloudNative-PG) with S3 backups
  - Redis StatefulSet (master)
  - Elasticsearch StatefulSet for full-text search
  - Custom HPA based on queue latency, backlog, connection metrics, and memory
  - PriorityClass: mastodon-critical (stateful), mastodon-high (deployments)
  - Pod topology spread and anti-affinity for high availability
- **CryptPad** - Privacy-respecting collaborative editor
- **Hypebot** - Automated community engagement bot (ghcr.io/goingdark-social/hypebot:v0.1.0)

## Common Design Patterns

### Kustomize Organization
- **Nested kustomization layers**: app root → configs/ → resources/ → resource subdirectories
- **Resource organization by type**: autoscaling/, disruption/, jobs/, monitoring/, networking/, secrets/, services/, storage/, workloads/
- **One resource per file** with descriptive names (e.g., `web-deployment.yaml`, `sidekiq-default-hpa.yaml`)
- **Strategic patches** in `patches/` directories (priority-patches.yaml, spread-patches.yaml)
- **ConfigMap generators** with multiple env files per component
- **Kustomization includes subdirectories**, not individual files

### Helm + Kustomize Integration
- Helm charts used **sparingly** for complex third-party software (ArgoCD, VictoriaMetrics, CloudNative-PG, cert-manager, External Secrets)
- Helm charts are **always** used with Kustomize overlays, never standalone
- Test with: `kustomize build --enable-helm <directory>` (requires network, 2-10 min)
- Helm values customization done via `values.yaml` files referenced in `kustomization.yaml`
- includeCRDs: true for operators (VictoriaMetrics, CloudNative-PG)

### Secret Management
- **ExternalSecrets** pattern for all sensitive data
- Secrets stored in Bitwarden, synced via External Secrets Operator
- Each namespace has `externalsecret.yaml` defining secrets to sync
- Reference format: `bitwarden-item-id` in ExternalSecret spec
- Never commit raw secrets to the repository

### HTTP Routing (Gateway API)
- **Gateway** resources define listeners and TLS termination (`gateway/gw-external.yaml`)
  - Cilium gateway class with load balancer IP annotation (io.cilium/lb-ipam-ips)
  - Listeners for apex domain and wildcard (*.goingdark.social, *.peekoff.com)
  - TLS certificates from cert-manager (wildcard certificates)
  - AllowedRoutes: namespaces.from=All
- **HTTPRoute** resources define routing rules per application
  - Pattern: One HTTPRoute per service, attached to shared Gateway
  - Path-based routing (PathPrefix matching)
  - Example: `/api/v1/streaming` → mastodon-streaming:4000, `/` → mastodon-web:3000
  - Hostname-based routing (e.g., `mastodon.goingdark.social`, `pad.goingdark.social`)

### Network Policies
- Default deny-all pattern with explicit allowlist rules
- Each application defines its own NetworkPolicy
- Common patterns:
  - Allow DNS (kube-dns/coredns)
  - Allow specific ingress from Gateway namespace
  - Allow egress to specific services (database, redis, etc.)

### Configuration Management
- **ConfigMaps** for non-sensitive config (Kustomize `configMapGenerator`)
- Environment-based approach: separate `.env` files per component
- Mastodon example: `mastodon-core.env`, `mastodon-database.env`, `mastodon-redis.env`
- ConfigMaps referenced as `envFrom` in deployments

### Autoscaling Strategy
- **HPA** for horizontal scaling using custom metrics (VictoriaMetrics + Prometheus Adapter)
  - External metrics via Prometheus Adapter (e.g., `ruby_http_request_queue_duration_seconds_p95`)
  - Resource metrics (memory utilization as safety net for Ruby apps)
  - Separate scaleUp/scaleDown policies with stabilization windows
  - Example: scaleUp (30s stabilization, +2 pods/30s), scaleDown (180s stabilization, -1 pod/60s)
- **VPA** in recommender mode only (no automatic updates to avoid disruption)
  - Separate VPA resources per component (controller, server, repo-server, applicationset)
  - Provides resource recommendations without automatic enforcement
- **Metrics collection**:
  - VMServiceScrape resources for custom metrics (port 9394 on Mastodon web)
  - VictoriaMetrics stores metrics, Prometheus Adapter exposes to HPA

### High Availability Patterns
- **PriorityClass**: Ensures critical workloads scheduled first
  - mastodon-critical (priority 1000000) for stateful workloads (PostgreSQL, Redis, Elasticsearch)
  - mastodon-high for application deployments
  - Applied via strategic patches in `patches/priority-patches.yaml`
- **Pod Anti-Affinity**: preferredDuringSchedulingIgnoredDuringExecution with weight 100
  - Spreads replicas across nodes when possible
  - Soft constraint - allows scheduling even if constraint can't be met
- **Topology Spread Constraints**: maxSkew=1, whenUnsatisfiable=ScheduleAnyway
  - Distributes pods evenly across kubernetes.io/hostname topology
  - Applied via strategic patches in `patches/spread-patches.yaml`
- **PodDisruptionBudgets**: Configured in disruption/ subdirectories

### Stateful Application Patterns
- **PostgreSQL (CloudNative-PG)**: Zalando postgres-operator
  - Spilo 17 containers, logical backups to S3 (daily at 3am)
  - SSL with verify-ca mode, password rotation disabled
  - PVC retention policy: retain on delete/scale
  - Custom resource: postgresql.acid.zalan.do/v1
- **Redis**: StatefulSet with master configuration
  - Persistent volume claims for data
  - NetworkPolicy for access control
- **Elasticsearch**: StatefulSet for full-text search
  - Dedicated storage, network policies

## Development Workflow

### Infrastructure Changes
```bash
cd opentofu
tofu fmt -write=true -diff  # Format code
tofu validate               # Validate syntax
tofu plan                   # Preview changes
```

### Kubernetes Manifest Changes
```bash
# Test without Helm (fast)
kustomize build apps/platform/mastodon

# Test with Helm (requires network, 2-10 min)
kustomize build --enable-helm apps/argocd

# Validate changes
kubectl diff -k apps/platform/mastodon
```

### Manual Apply (Development Only)
**CRITICAL**: Never apply directly from `base/` directories or individual resource files.

Always use Kustomize and apply from the application root:
```bash
# CORRECT: Apply from application root
kubectl apply -k apps/platform/mastodon

# WRONG: Do not apply from base or resource directories
kubectl apply -f apps/platform/mastodon/resources/  # ❌
kubectl apply -f apps/platform/mastodon/base/       # ❌
```

This ensures:
- All patches are applied correctly
- ConfigMaps are generated with proper naming
- Strategic merges execute in the correct order
- Kustomize transformers run properly

### Deployment
All deployments handled by ArgoCD GitOps - push to `main` branch and ArgoCD syncs automatically.

## Dependency Management

### Renovate Bot
- **Automated updates** for Helm charts, container images, and Kustomize resources
- Configuration: `renovate.json` in repository root
- **Enabled managers**: kubernetes, kustomize, helm-values
- **Commit pattern**: `chore(deps): update [component] to [version]`
- **Examples**:
  - `chore(deps): update helm release argo-cd to v8.5.7`
  - `chore(deps): update ghcr.io/glitch-soc/mastodon docker tag to v4.4.5`
  - `chore(deps): update postgres docker tag to v18`
- Pull requests created automatically, merge after validation

## Key Configuration Files

### Infrastructure
- `opentofu/kubernetes.tofu` - Main Talos cluster configuration using hcloud-k8s module
- `opentofu/.terraform.lock.hcl` - Provider version locks

### GitOps
- `kubernetes/application-set.yaml` - ArgoCD ApplicationSets for infrastructure and platform apps
  - **Infrastructure ApplicationSet**: sync-wave=-10, directories (argocd, base-system, database, crds, default, deployment, kube-system)
  - **Platform ApplicationSet**: sync-wave=0, directories (platform/*)
  - **Sync policy**: automated (prune + selfHeal), ServerSideApply, PruneLast, RespectIgnoreDifferences
  - **Retry backoff**: infrastructure (10s→3m), platform (5s→3m)
- `kubernetes/project.yaml` - ArgoCD project definitions (infrastructure, platform)
- `kubernetes/kustomization.yaml` - Root Kustomize configuration

### Mastodon Configuration
- `kubernetes/apps/platform/mastodon/kustomization.yaml` - Component orchestration with ConfigMaps
  - ConfigMapGenerator entries for all components (core, database, redis, search, features, external-services, web, sidekiq, streaming, jobs)
  - References nested resources/ and configs/ directories
  - Applies strategic patches for priority and spread
- `kubernetes/apps/platform/mastodon/configs/` - Environment-based configuration files (.env files)
- `kubernetes/apps/platform/mastodon/resources/` - Organized by resource type:
  - `workloads/` - Deployments, StatefulSets (web, streaming, sidekiq-*, database, redis, elasticsearch)
  - `autoscaling/` - HPA definitions (web, streaming, sidekiq-default, sidekiq-federation, sidekiq-background)
  - `networking/` - Services, HTTPRoutes, NetworkPolicies
  - `monitoring/` - VMServiceScrape resources
  - `secrets/` - ExternalSecret configurations
  - `storage/` - PersistentVolumeClaims
  - `jobs/` - Kubernetes Jobs (migrations, cache-recount, etc.)
  - `disruption/` - PodDisruptionBudgets
- `kubernetes/apps/platform/mastodon/patches/` - Strategic patches (priority, topology spread)

## Mastodon Autoscaling Strategy

The Mastodon deployment uses custom HPA metrics via VictoriaMetrics and Prometheus Adapter:

- **Web servers**: Scale on p95 queue time (>35ms) or backlog (>3 requests), with 80% memory target
  - Scale up: +2 pods every 30s
  - Scale down: -1 pod every 3 min (prevents flapping)
- **Sidekiq default**: Scale on queue latency >10s
- **Sidekiq federation**: Scale on queue latency >30s
- **Streaming**: Scale on connected clients (~200 per pod)

Metrics exposed via port 9394 on web pods, scraped by VMServiceScrape.

## Security Configuration

- **TLS**: cert-manager with Cloudflare DNS-01 challenge
- **Secrets**: External Secrets Operator integrated with Bitwarden
- **Network**: Cilium with encryption, network policies for service isolation
- **Firewall**: Hetzner Cloud firewall protecting Talos and K8s APIs
- **Security contexts**: Non-root users, capability dropping, read-only root filesystems
- **SSL**: PostgreSQL uses SSL with certificate verification (verify-ca mode)

## Maintenance Workflows

### Common Tasks

#### Version Updates
1. **Container images**: Update centralized image tags and digests in `kubernetes/apps/platform/mastodon/kustomization.yaml`
2. **Helm charts**: Renovate handles automatically, or manually update version in helmCharts section
3. **Testing**: `kustomize build apps/platform/[app]` (fast), `kustomize build --enable-helm apps/[app]` (slow)
4. **Validation**: `kubectl diff -k apps/platform/[app]` before committing

#### Configuration Changes
1. **Update .env files** in `apps/[app]/configs/` directory
2. **ConfigMaps regenerate** automatically via Kustomize configMapGenerator
3. **Pods restart** automatically when ConfigMap changes (ArgoCD selfHeal)
4. **Secrets**: Update in Bitwarden, External Secrets Operator syncs within 1h (or trigger manual sync)

#### Scaling Adjustments
1. **Manual scaling**: Update `replicas:` in Deployment manifest
2. **HPA tuning**: Modify metrics/thresholds in `resources/autoscaling/[component]-hpa.yaml`
3. **Autoscaler behavior**: Adjust stabilizationWindowSeconds, policies (pods, percent, periodSeconds)
4. **VPA recommendations**: Check VPA status for resource recommendation updates

#### Adding New Applications
1. **Create directory structure**: `apps/platform/[app]/` with namespace.yaml, kustomization.yaml
2. **Organize resources**: Follow pattern (workloads/, networking/, secrets/, etc.)
3. **Add to ApplicationSet**: Platform ApplicationSet auto-discovers via `platform/*` path filter
4. **Configure secrets**: Create ExternalSecret referencing Bitwarden items
5. **Networking**: Create HTTPRoute attached to external Gateway, configure NetworkPolicies

### Troubleshooting

#### ArgoCD Sync Issues
- **Check sync waves**: Infrastructure (-10) deploys before platform (0)
- **Namespace creation**: Ensure CreateNamespace=true in syncOptions
- **CRD availability**: CRDs must exist before custom resources (check crds/ directory)
- **View logs**: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller`

#### HPA Not Scaling
- **Verify Prometheus Adapter**: `kubectl get --raw /apis/external.metrics.k8s.io/v1beta1`
- **Check metric queries**: Ensure VMServiceScrape exists and metrics are being scraped
- **View HPA status**: `kubectl describe hpa [name] -n [namespace]`
- **Test metric query**: Query VictoriaMetrics directly for metric name

#### Pod Scheduling Failures
- **Check node resources**: `kubectl describe nodes` for allocatable vs requested
- **Verify tolerations**: Autoscaler nodes require toleration for "autoscaler-node" taint
- **Affinity rules**: Check anti-affinity and topology spread constraints
- **PriorityClass**: Lower priority pods may be preempted by higher priority

#### Secret Sync Issues
- **Check ExternalSecret status**: `kubectl describe externalsecret [name] -n [namespace]`
- **Verify Bitwarden store**: `kubectl describe clustersecretstore bitwarden-backend`
- **ESO logs**: `kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets`
- **Manual refresh**: Delete ExternalSecret and recreate to force immediate sync

## Tool Usage Guidelines

### MCP Servers and Specialized Agents

**CRITICAL**: Always use specialized subagents for significant tasks to improve speed, quality, and leverage expert knowledge.

#### When to Use Subagents
- **Infrastructure changes** → `terraform-specialist` (OpenTofu/Terraform expert)
- **Kubernetes manifests** → `kubernetes-architect` (K8s expert with GitOps, service mesh, platform engineering)
- **Security review** → `security-auditor` (DevSecOps, compliance, vulnerability assessment)
- **Testing** → `test-automator` or `tdd-orchestrator` (test automation and TDD practices)
- **Debugging** → `debugger` or `devops-troubleshooter` (incident response, observability)
- **Performance** → `performance-engineer` (optimization, observability, Core Web Vitals)
- **Code review** → `code-reviewer` (AI-powered analysis, security, performance)
- **Deployment** → `deployment-engineer` (CI/CD, GitOps, progressive delivery)
- **Database work** → `database-optimizer` or `database-admin` (performance, operations)
- **Documentation** → `api-documenter` or `docs-architect` (comprehensive technical docs)

#### Parallel Agent Execution
- **Launch agents in parallel** when tasks are independent
- Use single message with multiple Task tool calls (NOT separate messages)
- Example: Launch `kubernetes-architect` and `security-auditor` together for new feature

#### MCP Server Priority
- **ALWAYS use MCP servers** when available instead of manual tools (WebFetch, Bash commands, etc.)
- MCP-provided tools have fewer restrictions and better integration

## Performance Considerations

- **VPA recommender-only mode**: Prevents disruption from automatic resource updates
- **HPA scaling velocity**: Conservative scale-down (3min stabilization) vs aggressive scale-up (30s)
  - Prevents flapping during traffic spikes
  - Reduces cost from over-provisioning
- **Resource requests/limits**: Memory-focused for Ruby applications (CPU secondary)
  - Web pods: memory utilization target 80% as primary metric
  - CPU limits set but not primary scaling trigger
- **PodDisruptionBudgets**: Ensure minimum availability during voluntary disruptions
  - Configured per workload type in disruption/ subdirectories
- **Topology spread**: Soft constraints (ScheduleAnyway) prevent blocking deployments
- **Anti-affinity**: Preferred (not required) to allow scheduling under resource pressure

## File Organization Best Practices

- **One resource per file**: Exceptions for strategic patches applying to multiple resources
- **Descriptive filenames**: Component-type pattern (e.g., `web-deployment.yaml`, `sidekiq-default-hpa.yaml`)
- **Kustomization includes subdirectories**: Not individual files (reduces kustomization.yaml line count)
- **Separation of concerns**:
  - configs/ for configuration files (.env, values.yaml)
  - resources/ for Kubernetes manifests
  - patches/ for strategic patches
- **Resource type organization**: Group by function (autoscaling/, networking/, workloads/, etc.)
- **HTTPRoute per service**: Avoid combining multiple service routes in one HTTPRoute

## Important Notes

- All container images pinned to specific versions for stability (Renovate handles updates)
- VPA runs in recommender mode only (updater/admission disabled to prevent disruption)
- PostgreSQL includes daily logical backups to S3 (3am, configured via postgres-operator)
- ArgoCD manages all applications with automated sync (prune + selfHeal enabled)
- Cluster deletion protection disabled in OpenTofu (cluster_delete_protection = false)
- API access restricted by Hetzner Cloud Firewall to configured source IPs
- Cloudflare tunnel for secure inbound connectivity (UDP 8443)
- Renovate bot automatically creates PRs for dependency updates (kubernetes, helm-values, kustomize)
- DNS Configuration for Mail:
  - `mail.peekoff.com` should point to the external IP of the `stalwart-mail` LoadBalancer Service
  - `mailadmin.peekoff.com` should be proxied through Cloudflare, ensuring Cloudflare can reach the Gateway's private IP (e.g., via Cloudflare tunnel)
  - Cloudflare: Set DNS records for mail domains to "DNS only" to avoid proxying SMTP/IMAP/POP3 ports; admin UI can be proxied if origin is reachable

## JIT (Jump-In-Tree) Links

- [opentofu/AGENTS.md](opentofu/AGENTS.md)