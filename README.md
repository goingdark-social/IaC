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

- The `mastodon-web` service now exposes port 9394 so each pod's `/metrics` endpoint is reachable inside the cluster.
- VictoriaMetrics scrapes that endpoint through a `VMServiceScrape` and a Prometheus adapter publishes custom metrics for queue latency, backlog, and request rate.
- The horizontal pod autoscaler targets a 50 ms p95 queue duration, caps backlog at 20 pending requests, and still watches CPU at 70% so we have a safety net.
- Scale ups react inside 30 seconds and can add up to three pods at once, while scale downs wait three minutes before stepping back to avoid flapping.

## Tech Stack

**Infrastructure**: Hetzner Cloud, Talos Linux, OpenTofu
**Orchestration**: Kubernetes, ArgoCD, Cilium
**Monitoring**: VictoriaMetrics, VictoriaLogs, Grafana
**Security**: External Secrets, cert-manager, Gateway API