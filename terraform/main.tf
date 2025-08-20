# Network
resource "hcloud_network" "this" {
  name     = var.cluster_name
  ip_range = "10.0.0.0/16"
  labels   = { cluster = var.cluster_name }
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# Local values for single-node cluster
locals {
  cpn_private_ip = cidrhost(hcloud_network_subnet.nodes.ip_range, 100)
}

# Load balancer for Talos API and kube-apiserver
resource "hcloud_load_balancer" "main" {
  name               = "cpn"
  load_balancer_type = "lb11"
  network_zone       = "eu-central"
}

# Attach LB to the same private network
resource "hcloud_load_balancer_network" "main" {
  load_balancer_id = hcloud_load_balancer.main.id
  network_id       = hcloud_network.this.id
}

resource "hcloud_load_balancer_service" "main-kubectl" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "main-talosctl" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "tcp"
  listen_port      = 50000
  destination_port = 50000

  health_check {
    protocol = "tcp"
    port     = 50000
    interval = 15
    timeout  = 10
    retries  = 3
  }
}


# Talos base
resource "talos_machine_secrets" "this" {}

# Control plane config - use load balancer IP for cluster endpoint
data "talos_machine_configuration" "cpn" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${hcloud_load_balancer.main.ipv4}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    templatefile("${path.module}/templates/cpn.yaml.tmpl", {
      node_ip      = local.cpn_private_ip
      lb_ip        = hcloud_load_balancer_network.main.ip
      lb_ip_public = hcloud_load_balancer.main.ipv4
    })
  ]
  depends_on = [hcloud_load_balancer.main, hcloud_load_balancer_network.main]
}

# Control plane servers
resource "hcloud_server" "cpn" {
  count       = var.cpn_count
  name        = "cpn-${format("%02d", count.index)}"
  image       = var.hcloud_image
  server_type = "cpx21"
  location    = var.hcloud_location
  labels      = { type = "cpn" }

  user_data = data.talos_machine_configuration.cpn.machine_configuration

  network {
    network_id = hcloud_network_subnet.nodes.network_id
    ip         = cidrhost(hcloud_network_subnet.nodes.ip_range, count.index + 100)
    alias_ips  = []
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  depends_on = [hcloud_network_subnet.nodes]

  lifecycle {
    ignore_changes = [image, user_data, network]
  }
}

# Client configuration - use load balancer for external access
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [hcloud_load_balancer.main.ipv4]
  depends_on           = [hcloud_load_balancer.main]
}

# Target the LB to control planes over private IPs
resource "hcloud_load_balancer_target" "main" {
  count            = length(hcloud_server.cpn)
  type             = "server"
  load_balancer_id = hcloud_load_balancer.main.id
  server_id        = hcloud_server.cpn[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_server.cpn, hcloud_load_balancer_network.main]
}

# Apply Talos config to control planes
resource "talos_machine_configuration_apply" "cpn" {
  count                        = length(hcloud_server.cpn)
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cpn.machine_configuration
  node                        = hcloud_server.cpn[count.index].ipv4_address
}

# Worker config and servers
data "talos_machine_configuration" "wkn" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${hcloud_load_balancer.main.ipv4}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    templatefile("${path.module}/templates/wkn.yaml.tmpl", {})
  ]
  depends_on = [hcloud_load_balancer.main]
}

resource "hcloud_server" "wkn" {
  count       = var.wkn_count
  name        = "wkn-${format("%02d", count.index)}"
  image       = var.hcloud_image
  server_type = "cx22"
  location    = var.hcloud_location
  labels      = { type = "wkn" }

  user_data = data.talos_machine_configuration.wkn.machine_configuration

  network {
    network_id = hcloud_network_subnet.nodes.network_id
    ip         = cidrhost(hcloud_network_subnet.nodes.ip_range, count.index + 200)
    alias_ips  = []
  }

  depends_on = [hcloud_network_subnet.nodes]

  lifecycle {
    ignore_changes = [image, user_data, network]
  }
}

resource "talos_machine_configuration_apply" "wkn" {
  count                        = length(hcloud_server.wkn)
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.wkn.machine_configuration
  node                        = hcloud_server.wkn[count.index].ipv4_address
}

# Bootstrap
resource "talos_machine_bootstrap" "bootstrap" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = hcloud_load_balancer.main.ipv4
  node                 = hcloud_server.cpn[0].ipv4_address
  depends_on           = [talos_machine_configuration_apply.cpn]
}

# Health gate: skip Kubernetes checks and allow realistic startup time
# data "talos_cluster_health" "ready" {
#   depends_on           = [talos_machine_bootstrap.bootstrap]
#   client_configuration = data.talos_client_configuration.this.client_configuration
#   endpoints            = [hcloud_load_balancer.main.ipv4]

#   control_plane_nodes = [for i in range(var.cpn_count) : cidrhost(hcloud_network_subnet.nodes.ip_range, i + 100)]
#   worker_nodes        = [for i in range(var.wkn_count) : cidrhost(hcloud_network_subnet.nodes.ip_range, i + 200)]

#   skip_kubernetes_checks = true
#   timeouts               = { read = "30s" }
# }

# Kubeconfig from Talos, then write to disk
resource "talos_cluster_kubeconfig" "this" {
  endpoint             = hcloud_load_balancer.main.ipv4
  client_configuration = data.talos_client_configuration.this.client_configuration
  node                 = hcloud_server.cpn[0].ipv4_address
  #depends_on           = [data.talos_cluster_health.ready]
}

resource "local_sensitive_file" "kubeconfig" {
  filename = "${path.module}/kubeconfig"
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
}



resource "helm_release" "cilium" {
  provider   = helm.addons
  depends_on = [local_sensitive_file.kubeconfig]

  name       = "cilium"
  chart      = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io/"
  version    = "1.18.1"
  values     = [file("manifests/cilium.yaml")]
}

resource "kubernetes_namespace" "argocd" {
  provider   = kubernetes.addons
  depends_on = [local_sensitive_file.kubeconfig]
  metadata { name = "argocd" }
}

resource "kubernetes_namespace" "base-system" {
  provider   = kubernetes.addons
  depends_on = [local_sensitive_file.kubeconfig]
  metadata { name = "base-system" }
}

resource "kubernetes_secret" "hcloud" {
  provider   = kubernetes.addons
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }
  data = {
    token   = var.hcloud_token
    image   = var.hcloud_image
    network = hcloud_network.this.id
  }
}
