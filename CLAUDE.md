# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Kubernetes infrastructure-as-code repository for deploying production infrastructure on Hetzner Cloud. The repository uses OpenTofu for infrastructure provisioning, Talos Linux for the Kubernetes operating system, and ArgoCD for GitOps-based application deployment.

## Repository Structure

The repository is organized into two main sections:

### Infrastructure (`opentofu/`)
- **`kubernetes.tofu`** - Main cluster configuration using hcloud-k8s module
- **`.terraform.lock.hcl`** - Provider version locks for reproducible builds
- **`talosconfig`** - Talos cluster configuration (generated)
- **`kubeconfig`** - Kubernetes cluster access (generated)

### Applications (`kubernetes/`)
GitOps manifests organized by namespace and function:

- **`kubernetes/apps/argocd/`** - ArgoCD deployment with Helm charts
- **`kubernetes/apps/base-system/`** - Core infrastructure services:
  - `cert-manager/` - TLS certificate management with Cloudflare/Bitwarden integration
  - `cilium/` - eBPF-based networking with BGP and IP pools
  - `external-secrets/` - Bitwarden secrets integration
  - `victoriametrics/` - Monitoring stack (metrics, logs, alerting)
  - `cloudflared/` - Cloudflare tunnel for secure access
  - `gateway/` - Gateway API for modern ingress
  - `vpa/` - Vertical Pod Autoscaler
- **`kubernetes/apps/database/`** - Database operators and services
- **`kubernetes/apps/platform/`** - Community applications:
  - `mastodon/` - Social media platform (glitch-soc fork with custom configuration)
  - `hypebot/` - Automated community engagement bot
  - `cryptpad/` - Privacy-respecting collaborative editor

## Architecture Patterns

### GitOps Deployment
- ArgoCD ApplicationSets automatically deploy from `kubernetes/` directory
- Each app has its own namespace and ArgoCD project for isolation
- Kustomize with Helm support for configuration management

### Infrastructure Provisioning
- OpenTofu manages Hetzner Cloud resources (compute, networking, storage)
- Talos Linux provides immutable, Kubernetes-optimized nodes
- Automated firewall configuration for API access

### Monitoring & Observability
- VictoriaMetrics for metrics collection and storage
- VictoriaLogs for centralized logging
- Grafana for visualization and alerting
- Custom autoscaling based on application-specific metrics

## Development Commands

### Infrastructure Management
```bash
# Format and validate OpenTofu configuration
cd opentofu && tofu fmt -write=true -diff
cd opentofu && tofu validate

# Initialize and plan infrastructure changes
cd opentofu && tofu init -upgrade    # Takes 2-5 minutes, set timeout 10+ minutes
cd opentofu && tofu plan             # Takes 1-3 minutes, set timeout 10+ minutes
cd opentofu && tofu apply            # Takes 15-45 minutes, set timeout 60+ minutes

# Access cluster after deployment
export TALOSCONFIG=opentofu/talosconfig
export KUBECONFIG=opentofu/kubeconfig
```

### Kubernetes Manifest Validation
```bash
# Basic YAML syntax validation
find . -name "*.yaml" -o -name "*.yml" | head -10 | xargs -I {} python3 -c "import yaml; yaml.safe_load(open('{}', 'r'))"

# Kustomize validation (offline)
cd kubernetes/apps/base-system && kustomize build .
cd kubernetes/apps/platform && kustomize build .

# Kustomize with Helm (requires network, takes 2-10 minutes)
cd kubernetes && kustomize build --enable-helm .
```

### Deployment and Monitoring
```bash
# Bootstrap GitOps deployment
kubectl apply -f kubernetes/application-set.yaml

# Check ArgoCD applications
kubectl get applications -n argocd
kubectl get applicationsets -n argocd

# Monitor cluster health
talosctl get member
kubectl get nodes -o wide
kubectl get pods -A

# Application-specific monitoring
kubectl logs -n mastodon -l app=mastodon-web
kubectl logs -n hypebot -l app=hypebot
kubectl get postgresql -n database
```

## Key Configuration Files

### Infrastructure
- `opentofu/kubernetes.tofu` - Main cluster configuration
- `opentofu/.terraform.lock.hcl` - Provider version locks

### GitOps
- `kubernetes/application-set.yaml` - ArgoCD ApplicationSet for infrastructure apps
- `kubernetes/project.yaml` - ArgoCD project definition
- `kubernetes/kustomization.yaml` - Root Kustomize configuration

### Applications
- `kubernetes/apps/*/kustomization.yaml` - Component-specific configurations
- `kubernetes/apps/base-system/cert-manager/` - TLS certificate management
- `kubernetes/apps/platform/mastodon/` - Mastodon deployment with custom scaling

## Security and Operations

### Secrets Management
- Bitwarden integration via external-secrets for credential management
- TLS certificates automatically provisioned via cert-manager with Cloudflare DNS
- Firewall rules automatically configured to allow API access from deployment IP

### Autoscaling Configuration
The deployment includes sophisticated autoscaling:
- **Mastodon Web**: Scales on p95 queue latency (>35ms) and backlog (>3 requests)
- **Sidekiq Workers**: Scale on queue latency metrics (10s default, 30s federation)
- **Streaming API**: Scales based on connected client count (~200 per pod)
- **VPA**: Available for vertical scaling recommendations

### Backup and Recovery
- PostgreSQL with WAL-G backup system for disaster recovery
- SSL database connections with certificate verification
- Persistent storage for all stateful services

## Timing Expectations

### Fast Operations (<1 second)
- `tofu fmt` and `tofu validate` (after init)
- `kustomize build` for simple manifests
- Basic kubectl operations

### Network-Dependent Operations (1-15 minutes)
- `tofu init` - Provider downloads (2-5 minutes)
- `tofu plan` - API calls to Hetzner (1-3 minutes)
- Kustomize with Helm charts (2-10 minutes)

### Long Operations (15+ minutes)
- `tofu apply` - Full cluster deployment (15-45 minutes)
- ArgoCD initial synchronization (10-20 minutes)

**Important**: Never cancel long-running operations as they may leave infrastructure in an inconsistent state.