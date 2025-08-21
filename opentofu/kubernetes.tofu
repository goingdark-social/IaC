module "kubernetes" {
  source  = "hcloud-k8s/kubernetes/hcloud"
  version = "2.7.2"

  cluster_name              = "goingdark"
  hcloud_token              = var.hcloud_token
  cluster_delete_protection = true

  cluster_kubeconfig_path  = "kubeconfig"
  cluster_talosconfig_path = "talosconfig"

  control_plane_nodepools = [
    { name = "control", type = "cpx11", location = "hel1", count = 3 }
  ]
  worker_nodepools = [
    { name = "worker", type = "cpx11", location = "hel1", count = 3 }
  ]

  cert_manager_enabled           = true
  ingress_nginx_enabled          = false
  longhorn_enabled               = true
  longhorn_default_storage_class = true

  firewall_use_current_ipv4      = true
  firewall_use_current_ipv6      = false
  kube_api_load_balancer_enabled = false

  cluster_autoscaler_nodepools = [
    {
      name     = "autoscaler"
      type     = "cpx11"
      location = "hel1"
      min      = 0
      max      = 3
      labels   = { "autoscaler-node" = "true" }
      taints   = ["autoscaler-node=true:NoExecute"]
    }
  ]

  cluster_autoscaler_helm_values = {
    extraArgs = {
      enforce-node-group-min-size   = true
      scale-down-delay-after-add    = "45m"
      scale-down-delay-after-delete = "4m"
      scale-down-unneeded-time      = "5m"
    }
  }

  cilium_encryption_enabled = true
  cilium_encryption_type    = "wireguard"

  talos_extra_remote_manifests = [
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml",
    "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml",
    "https://raw.githubusercontent.com/goingdark-social/IaC/refs/heads/main/kubernetes/project.yaml",
    "https://raw.githubusercontent.com/goingdark-social/IaC/refs/heads/main/kubernetes/application-set.yaml"
  ]

  talos_extra_inline_manifests = [
    {
      name     = "namespace-argocd"
      contents = <<-EOF
        apiVersion: v1
        kind: Namespace
        metadata:
          name: argocd
      EOF
    },
    {
      name     = "bitwarden-secret"
      contents = <<-EOF
      apiVersion: v1
      kind: Secret
      metadata:
        name: bitwarden-access-token
        namespace: external-secrets
      data:
        token: ${base64encode(var.bitwarden_token)}
    EOF
    },
    {
      name     = "cloudflare-secret"
      contents = <<-EOF
        apiVersion: v1
        kind: Secret
        metadata:
          name: cert-manager-secrets
          namespace: cert-manager
        data:
          cloudflare-api-token: ${base64encode(var.cloudflare_api_token)}
      EOF
    }
  ]
} # <-- closes module block

# root-level variables
variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token"
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token"
}

variable "bitwarden_token" {
  type        = string
  sensitive   = true
  description = "Bitwarden access token for External-Secrets"
}
