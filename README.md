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
- The web autoscaler scales when p95 queue time stays over 35 ms or backlog rises above three requests, and it keeps an 80 % memory target as a safety net.
- Scale ups can add two pods every 30 seconds, while scale downs wait three minutes before stepping back to avoid flapping.
- Sidekiq default and federation workers scale on the `sidekiq_queue_latency_seconds` metric (10 seconds for default, 30 seconds for federation) so they grow only when the queues back up.
- Streaming workers follow the `mastodon_streaming_connected_clients` metric and add capacity once a pod carries around 200 live connections.

## Autoscaler Node Pool Placement

- The autoscaler node pool is now limited to stateless deployments that the descheduler can freely evict.
- Stateful components like PostgreSQL, Redis, and Elasticsearch, along with single-replica Sidekiq and streaming workers, are pinned to the fixed worker pool so scale-down drains stay possible.
- The descheduler policy now treats nodes below roughly 40 % utilization as underused and balances pods away from the autoscaler nodes so Cluster Autoscaler can remove idle machines.

## Worker Node Sysctls

- Talos applies `vm.max_map_count=262144` to every worker through OpenTofu so Elasticsearch and other mmap-heavy services come up cleanly on fresh nodes with no manual tuning.

## Gateway API Observability

- `kube-state-metrics` now ships the Kuadrant CustomResourceState bundle so VictoriaMetrics receives the `gatewayapi_*` series for GatewayClasses, Gateways, HTTPRoutes, TCPRoutes, TLSRoutes, GRPCRoutes, and UDPRoutes.
- The Grafana sidecar auto-imports the Gateway API dashboards that live in `kubernetes/apps/base-system/victoriametrics/dashboards/`; each ConfigMap is labeled `grafana_dashboard=1` so the new boards show up without manual imports.
- All dashboards point at the VictoriaMetrics datasource, so the existing scrape jobs and retention settings still apply—no extra Prometheus configuration is required.

## Mastodon Tor Access

- The external gateway exposes an HTTP listener on port 80 so Tor traffic reaches the cluster without onion TLS termination.
- A dedicated HTTPRoute publishes the `.onion` hostname, sends `/api/v1/streaming` requests to the streaming service, routes everything else to the web pods, and adds an `Onion-Location` response header for Tor Browser.
- A Tor hidden-service deployment forwards onion requests to the gateway load balancer and stores the generated hostname on a persistent volume so it survives pod restarts.
- The `mastodon-app-secrets` ExternalSecret carries the onion hostname from Bitwarden so the value stays out of the repo and can be rotated alongside the Tor key material.
- A Tor HTTP proxy runs inside the cluster on port 8118 and Mastodon points both `http_proxy` and `http_hidden_proxy` at it for federation with onion-only peers.
- Mastodon sets `ALLOW_ACCESS_TO_HIDDEN_SERVICE=true` so it accepts the onion host while keeping HTTPS for the public domain.

## Tech Stack

**Infrastructure**: Hetzner Cloud, Talos Linux, OpenTofu
**Orchestration**: Kubernetes, ArgoCD, Cilium
**Monitoring**: VictoriaMetrics, VictoriaLogs, Grafana
**Security**: External Secrets, cert-manager, Gateway API
