# goingdark.social Infrastructure

> [!NOTE]  
> The code included in this repository is not meant to be run as-is. It's a collection of infrastructure code and Kubernetes manifests used to deploy the goingdark.social Kubernetes cluster. You will need to adapt the code to your own needs and environment.

## Overview

This repository contains the complete infrastructure-as-code setup for deploying our production Kubernetes cluster on Hetzner Cloud. We run a Mastodon community focused on homelabs, self-hosting, and privacy advocacy.

The project uses:

- **OpenTofu** - Infrastructure provisioning and management
- **Talos Linux** - Kubernetes-optimized operating system
- **ArgoCD** - GitOps continuous deployment
- **Cilium** - eBPF-based container networking
- **VictoriaMetrics** - Monitoring and observability stack
- **Gateway API** - Modern ingress management

The infrastructure follows GitOps principles with ArgoCD managing application deployments from the `kubernetes/` directory.

## Project Structure

- [`opentofu/`](opentofu/) - Hetzner Cloud infrastructure code
- [`kubernetes/apps/argocd/`](kubernetes/apps/argocd/) - GitOps deployment controller
- [`kubernetes/apps/base-system/`](kubernetes/apps/base-system/) - Core cluster services (networking, monitoring, certificates)
- [`kubernetes/apps/platform/`](kubernetes/apps/platform/) - Community applications
  - [`mastodon/`](kubernetes/apps/platform/mastodon/) - Our Mastodon instance (glitch-soc)
  - [`cryptpad/`](kubernetes/apps/platform/cryptpad/) - Privacy-respecting collaborative editor
  - [`hypebot/`](kubernetes/apps/platform/hypebot/) - Community engagement automation
- [`kubernetes/apps/database/`](kubernetes/apps/database/) - Database operators and tooling

## Deploy Infrastructure

Install [OpenTofu](https://opentofu.org/docs/intro/install/) first, then provision the Hetzner Cloud infrastructure:

```bash
cd opentofu
tofu init -upgrade
tofu plan     # Review planned changes
tofu apply    # Deploy infrastructure
```

This creates the Kubernetes cluster, networking, storage, and security groups as defined in the OpenTofu configuration files.

## Bootstrap Applications

After infrastructure deployment, bootstrap the cluster with applications:

```bash
# Set up cluster access
export TALOSCONFIG=./opentofu/talosconfig
export KUBECONFIG=./opentofu/kubeconfig

# Deploy all applications via ArgoCD
kubectl apply -f kubernetes/application-set.yaml
```

This bootstrap process installs:
- ArgoCD for GitOps deployments
- Core networking (Cilium with encryption)
- Certificate management (cert-manager)
- Monitoring stack (VictoriaMetrics, Grafana)
- External secrets management
- Our community applications (Mastodon, CryptPad, Hypebot)

## What's Running

Once deployed, the cluster hosts:

- **Mastodon** - Our community social platform with 1000 character posts
- **CryptPad** - Collaborative document editing without surveillance
- **Hypebot** - Automated community engagement and post boosting
- **Grafana** - Infrastructure monitoring and alerting
- **PostgreSQL** - Primary database for Mastodon
- **Redis** - Caching layer for improved performance

All applications are managed through ArgoCD and deploy automatically when changes are pushed to the `kubernetes/` directory.

## Mastodon Web Metrics and Autoscaling

- The `mastodon-web` deployment scales primarily on memory pressure (75% target) with CPU as a secondary signal at 70% utilization.
- Scale ups add two pods at a time with a 30 second stabilization window so we can handle sudden traffic while still capping the pool at six replicas.
- Scale downs wait three minutes between steps to avoid disconnecting active sessions too aggressively.
- Streaming workers now scale between one and five replicas with a 50% CPU target so websocket fan-out stays snappy even when a wave of followers lands at once.

## Mastodon Background Queues

- Sidekiq is split into four deployments: default (interactive work), federation (push/ingress), background (mailers and slow jobs), and scheduler (cron jobs).
- Each deployment has its own HPA tuned for that workload, so heavy federation traffic can burst without starving notifications or cron jobs.
- Database pool sizes now match the thread counts in each queue, and PodDisruptionBudgets keep at least one worker for every queue during maintenance.

## Tech Stack

**Infrastructure**: Hetzner Cloud, Talos Linux, OpenTofu
**Orchestration**: Kubernetes, ArgoCD, Cilium
**Monitoring**: VictoriaMetrics, VictoriaLogs, Grafana
**Security**: External Secrets, cert-manager, Gateway API