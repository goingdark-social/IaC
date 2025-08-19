locals {
  lb_enabled          = true
  cpn0_priv_ip        = cidrhost(hcloud_network_subnet.nodes.ip_range, 100)
  # Talos cluster endpoint (what nodes use)
  api_endpoint_config = local.lb_enabled ? hcloud_load_balancer.main[0].network_ip : local.cpn0_priv_ip
  # Client endpoint (what terraform/helm uses)
  api_endpoint_client = local.lb_enabled ? hcloud_load_balancer.main[0].ipv4 : hcloud_server.cpn[0].ipv4_address
}



# Internal network
resource "hcloud_network" "this" {
  name     = var.cluster_name
  ip_range = "10.0.0.0/16"
  labels = {
    "cluster" = var.cluster_name
  }
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# NLB for Talos OS and Kubernetes
# NLB for Talos OS and Kubernetes
resource "hcloud_load_balancer" "main" {
  count              = local.lb_enabled ? 1 : 0
  name               = "cpn"
  load_balancer_type = "lb11"
  network_zone       = "eu-central"
}

resource "hcloud_load_balancer_network" "lb_net" {
  count            = local.lb_enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.main[0].id
  subnet_id        = hcloud_network_subnet.nodes.id
}

resource "hcloud_load_balancer_service" "main-kubectl" {
  count            = local.lb_enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.main[0].id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
}

resource "hcloud_load_balancer_service" "main-talosctl" {
  count            = local.lb_enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.main[0].id
  protocol         = "tcp"
  listen_port      = 50000
  destination_port = 50000
}

resource "hcloud_load_balancer_target" "main" {
  count            = local.lb_enabled ? length(hcloud_server.cpn) : 0
  type             = "server"
  load_balancer_id = hcloud_load_balancer.main[0].id
  server_id        = hcloud_server.cpn[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.lb_net]
}


# Talos OS base configuration
resource "talos_machine_secrets" "this" {}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.api_endpoint_client]
}

# machine configs
data "talos_machine_configuration" "cpn" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.api_endpoint_config}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches   = [templatefile("${path.module}/templates/cpn.yaml.tmpl", {})]
}

data "talos_machine_configuration" "wkn" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.api_endpoint_config}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches   = [templatefile("${path.module}/templates/wkn.yaml.tmpl", {})]
}



resource "hcloud_server" "cpn" {
  name        = "cpn-${format("%02d", count.index)}"
  image       = var.hcloud_image
  count       = var.cpn_count
  server_type = "cpx21"
  location    = var.hcloud_location
  labels = {
    type = "cpn"
  }
  user_data = data.talos_machine_configuration.cpn.machine_configuration
  network {
    network_id = hcloud_network_subnet.nodes.network_id
    ip = cidrhost(hcloud_network_subnet.nodes.ip_range, count.index + 100)
    alias_ips = [] # https://github.com/hetznercloud/terraform-provider-hcloud/issues/650
  }
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
  depends_on = [
    data.talos_machine_configuration.cpn,
    hcloud_network_subnet.nodes
  ]
  lifecycle {
    ignore_changes = [
      image,
      user_data,
      network
    ]
  }
}

resource "talos_machine_configuration_apply" "cpn" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cpn.machine_configuration
  count = length(hcloud_server.cpn)
  node                        = hcloud_server.cpn[count.index].ipv4_address
}

# Worker nodes

resource "hcloud_server" "wkn" {
  name        = "wkn-${format("%02d", count.index)}"
  image       = var.hcloud_image
  count       = var.wkn_count
  server_type = "cpx21"
  location    = var.hcloud_location
  labels = {
    type = "wkn"
  }
  user_data = data.talos_machine_configuration.wkn.machine_configuration
  network {
    network_id = hcloud_network_subnet.nodes.network_id
    ip = cidrhost(hcloud_network_subnet.nodes.ip_range, count.index + 200)
    alias_ips = [] # https://github.com/hetznercloud/terraform-provider-hcloud/issues/650
  }
  depends_on = [
    data.talos_machine_configuration.cpn,
    hcloud_network_subnet.nodes
  ]
  lifecycle {
    ignore_changes = [
      image,
      user_data,
      network
    ]
  }
}

resource "talos_machine_configuration_apply" "wkn" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.wkn.machine_configuration
  count = length(hcloud_server.wkn)
  node                        = hcloud_server.wkn[count.index].ipv4_address
}

resource "talos_machine_bootstrap" "bootstrap" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = local.api_endpoint_client
  node                 = hcloud_server.cpn[0].ipv4_address

  lifecycle { prevent_destroy = true }
  depends_on = [hcloud_server.cpn, talos_machine_configuration_apply.cpn]
}


# data "talos_cluster_health" "ready" {
#   client_configuration   = talos_machine_secrets.this.client_configuration
#   endpoints              = [local.api_endpoint_client]
#   control_plane_nodes    = [for s in hcloud_server.cpn : s.ipv4_address]
#   worker_nodes           = [for s in hcloud_server.wkn : s.ipv4_address]
#   skip_kubernetes_checks = true
#   depends_on             = [talos_machine_bootstrap.bootstrap]
# }

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = hcloud_server.cpn[0].ipv4_address
  endpoint             = local.api_endpoint_client
  depends_on           = [talos_machine_bootstrap.bootstrap]
}


module "addons" {
  source = "./modules/addons"

  api_server_host    = local.api_endpoint_client
  client_cert_b64    = talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate
  client_key_b64     = talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key
  ca_cert_b64        = talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate
  hcloud_token       = var.hcloud_token
  hcloud_image       = var.hcloud_image
  hcloud_network_id  = hcloud_network.this.id

  depends_on = [local_sensitive_file.kubeconfig]
}

