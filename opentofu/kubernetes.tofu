module "kubernetes" {
  source  = "hcloud-k8s/kubernetes/hcloud"
  version = "3.0.3"

  cluster_name              = "goingdark"
  hcloud_token              = var.hcloud_token
  cluster_delete_protection = false

  # Configure cluster access for public networking to allow bootstrap
  cluster_access = "public"

  cluster_kubeconfig_path  = "kubeconfig"
  cluster_talosconfig_path = "talosconfig"

  control_plane_nodepools = [
    { name = "control", type = "cx22", location = "hel1", count = 1 }
  ]
  worker_nodepools = [
    { name = "worker", type = "cx22", location = "hel1", count = 1 }
  ]
  # Core Components (enabled by default)
  cilium_enabled                     = true
  talos_backup_s3_enabled            = true
  talos_ccm_enabled                  = true
  talos_coredns_enabled              = true
  hcloud_ccm_enabled                 = true
  hcloud_csi_enabled                 = true
  metrics_server_enabled             = true
  prometheus_operator_crds_enabled   = true

  # Additional Components (disabled by default)
  cert_manager_enabled           = false
  ingress_nginx_enabled          = false
  longhorn_enabled               = false
  longhorn_default_storage_class = false

  # Enable etcd backup by defining one of these variables:
  #talos_backup_s3_endpoint    = "https://..."
  #talos_backup_s3_hcloud_url  = "https://<bucket>.<location>.your-objectstorage.com"


  hcloud_csi_storage_classes = [
    {
      name                = "hcloud-volumes-encrypted-xfs"
      encrypted           = true
      defaultStorageClass = true
      reclaimPolicy       = "Retain"
      extraParameters     = {
        "csi.storage.k8s.io/fstype" = "xfs"
        "fsFormatOption"            = "-i nrext64=1"
      }
    }
  ]

  hcloud_csi_encryption_passphrase = var.hcloud_csi_encryption_passphrase

  firewall_use_current_ipv4      = false
  firewall_use_current_ipv6      = false
  firewall_api_source            = var.firewall_api_source
  kube_api_load_balancer_enabled = false
  #kube_api_hostname              = "kube-api.goingdark.social"
firewall_extra_rules = [
  {
    description = "Allow UDP to Cloudflare on port 8443"
    direction   = "in"
    source_ips  = ["0.0.0.0/0", "::/0"]
    protocol    = "udp"
    port        = "8443"
  },
  {
    description = "Allow inbound established UDP responses"
    direction   = "in"
    source_ips  = ["0.0.0.0/0", "::/0"]
    protocol    = "udp"
    port        = "32768-65535"
  }
]

  # Enable public IPv4 for both internet access and cluster bootstrap
  talos_public_ipv4_enabled = true
  talos_public_ipv6_enabled = false

  

cluster_autoscaler_nodepools = [
  {
    name     = "autoscaler"
    type     = "cx22"
    location = "hel1"
    min      = 0
    max      = 4
    labels   = { "autoscaler-node" = "true" }
    taints   = ["autoscaler-node=true:NoSchedule"]
  }
]

cluster_autoscaler_helm_values = {
  extraArgs = {
    scale-down-delay-after-add    = "10m"   # Wait longer after scaling up
    scale-down-delay-after-delete = "10m"   # Quick retry on failed scale-down
    scale-down-unneeded-time      = "8m"    # Conservative for media/federation bursts
    "balance-similar-node-groups" = "true"
    "expander" = "least-waste"
  }
}




  cilium_encryption_enabled = true
  cilium_encryption_type    = "wireguard"

  talos_extra_remote_manifests = [
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml",
  ]

  # talos_extra_inline_manifests = [
  #   {
  #     name     = "namespace-argocd"
  #     contents = <<-EOF
  #       apiVersion: v1
  #       kind: Namespace
  #       metadata:
  #         name: argocd
  #     EOF
  #   },
  #       {
  #     name     = "namespace-eso"
  #     contents = <<-EOF
  #       apiVersion: v1
  #       kind: Namespace
  #       metadata:
  #         name: external-secrets
  #     EOF
  #   },
  #   {
  #     name     = "bitwarden-secret"
  #     contents = <<-EOF
  #     apiVersion: v1
  #     kind: Secret
  #     metadata:
  #       name: bitwarden-access-token
  #       namespace: external-secrets
  #     data:
  #       token: ${base64encode(var.bitwarden_token)}
  #   EOF
  #   },
  #   {
  #     name     = "cloudflare-secret"
  #     contents = <<-EOF
  #       apiVersion: v1
  #       kind: Secret
  #       metadata:
  #         name: cloudflare-api-token
  #         namespace: cert-manager
  #       data:
  #         cloudflare-api-token: ${base64encode(var.cloudflare_api_token)}
  #     EOF
  #   }
  # ]
} # <-- closes module block

# root-level variables
variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token"
}

variable "firewall_api_source" {
  type        = list(string)
  description = "List of source IPs for the firewall"
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

variable "hcloud_csi_encryption_passphrase" {
  type        = string
  sensitive   = true
  description = "Encryption passphrase for Hetzner CSI (LUKS)."
}
