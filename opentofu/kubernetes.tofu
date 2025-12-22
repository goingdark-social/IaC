terraform {
  required_version = ">= 1.9.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.52.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.9.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0.2"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

module "kubernetes" {
  source  = "hcloud-k8s/kubernetes/hcloud"
  version = "3.2.0"

  cluster_name              = "goingdark"
  hcloud_token              = var.hcloud_token
  cluster_delete_protection = false

  # Configure cluster access for public networking to allow bootstrap
  cluster_access = "public"

  cluster_kubeconfig_path  = "kubeconfig"
  cluster_talosconfig_path = "talosconfig"

  control_plane_nodepools = [
    { name = "control", type = "cx33", location = "hel1", count = 1 }
  ]
  worker_nodepools = [
    # Primary general-purpose worker nodepool (larger instance type)
    { name = "worker", type = "cx43", location = "hel1", count = 1 },
    # Secondary worker nodepool (smaller instance type) for mixed workloads / cost optimization
    { name = "worker-secondary", type = "cx33", location = "hel1", count = 1 }
  ]
  worker_config_patches = [
    {
      machine = {
        sysctls = {
          "vm.max_map_count" = "262144"
        }
      }
    }
  ]
  # Core Components (enabled by default)
  cilium_enabled                   = true
  talos_backup_s3_enabled          = true
  talos_ccm_enabled                = true
  talos_coredns_enabled            = true
  hcloud_ccm_enabled               = true
  hcloud_csi_enabled               = true
  metrics_server_enabled           = true
  prometheus_operator_crds_enabled = true

  # Additional Components (disabled by default)
  cert_manager_enabled           = false
  ingress_nginx_enabled          = false
  longhorn_enabled               = false
  longhorn_default_storage_class = false

  # Enable etcd backup by defining one of these variables:
  #talos_backup_s3_endpoint    = "https://..."
  #talos_backup_s3_hcloud_url  = var.s3_url
  talos_backup_s3_region   = var.s3_region
  talos_backup_s3_endpoint = var.s3_endpoint
  talos_backup_s3_bucket   = var.s3_bucket
  #  talos_backup_s3_prefix   = var.s3_prefix

  # Use path-style URLs (set true if required by your provider)
  talos_backup_s3_path_style = true

  # Access credentials
  talos_backup_s3_access_key = var.s3_access_key
  talos_backup_s3_secret_key = var.s3_secret_key


  # Optional: Change schedule (cron syntax)
  talos_backup_schedule = "0 * * * *"

  hcloud_csi_storage_classes = [
    {
      name                = "hcloud-volumes-encrypted-xfs"
      encrypted           = true
      defaultStorageClass = true
      reclaimPolicy       = "Retain"
      extraParameters = {
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
    },
    {
      description = "Allow SMTP (port 25)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "25"
    },
    {
      description = "Allow SMTP Submission (port 587)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "587"
    },
    {
      description = "Allow SMTPS (port 465)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "465"
    },
    {
      description = "Allow IMAP (port 143)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "143"
    },
    {
      description = "Allow IMAPS (port 993)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "993"
    },
    {
      description = "Allow POP3 (port 110)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "110"
    },
    {
      description = "Allow POP3S (port 995)"
      direction   = "in"
      source_ips  = ["0.0.0.0/0", "::/0"]
      protocol    = "tcp"
      port        = "995"
    }
  ]

  # Enable public IPv4 for both internet access and cluster bootstrap
  talos_public_ipv4_enabled = true
  talos_public_ipv6_enabled = false



  cluster_autoscaler_nodepools = [
    {
      name     = "autoscaler"
      type     = "cx43"
      location = "hel1"
      min      = 0
      max      = 2
      labels   = { "autoscaler-node" = "true" }
      taints   = ["autoscaler-node=true:NoSchedule"]
    }
  ]

  cluster_autoscaler_helm_values = {
    extraArgs = {
      scale-down-delay-after-add       = "10m"  # Wait longer after scaling up
      scale-down-delay-after-delete    = "10m"  # Quick retry on failed scale-down
      scale-down-unneeded-time         = "8m"   # Conservative for media/federation bursts
      scale-down-utilization-threshold = "0.75" # Allow scale-down at 75% utilization (default 50%)
      balance-similar-node-groups      = "true"
      expander                         = "least-waste"
    }
  }




  cilium_encryption_enabled = true
  cilium_encryption_type    = "wireguard"

  talos_extra_remote_manifests = [
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml",
  ]

  talos_extra_inline_manifests = [
    {
      name = "cilium-settings"
      contents = join("\n---\n", [
        file("${path.root}/../kubernetes/apps/base-system/cilium/announce.yaml"),
        file("${path.root}/../kubernetes/apps/base-system/cilium/ip-pool.yaml"),
        format(
          "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-helm-values\n  namespace: kube-system\n  labels:\n    app.kubernetes.io/name: cilium-helm-values\n    app.kubernetes.io/managed-by: talos-inline\n  data:\n    values.yaml: |-\n%s\n",
          indent(6, trimspace(file("${path.root}/../kubernetes/apps/base-system/cilium/values.yaml")))
        ),
      ])
    },
  ]
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

variable "cloudflare-api-token" {
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

variable "s3_endpoint" {
  type        = string
  sensitive   = true
  description = "s3_endpoint"
}

variable "s3_region" {
  type        = string
  sensitive   = true
  description = "s3_region"
}

variable "s3_bucket" {
  type        = string
  sensitive   = true
  description = "s3_bucket"
}
# variable "s3_prefix" {
#   type        = string
#   sensitive   = true
#   description = "s3_prefix"
# }
variable "s3_access_key" {
  type        = string
  sensitive   = true
  description = "s3_access_key"
}
variable "s3_secret_key" {
  type        = string
  sensitive   = true
  description = "s3_access_key"
}

# Floating IP for Stalwart mail server
resource "hcloud_floating_ip" "mail" {
  type          = "ipv4"
  home_location = "hel1"
  description   = "Stalwart mail server VIP"
}

# Reverse DNS for mail server
resource "hcloud_rdns" "mail" {
  floating_ip_id = hcloud_floating_ip.mail.id
  ip_address     = hcloud_floating_ip.mail.ip_address
  dns_ptr        = "mail.peekoff.com"
}

# Output the Floating IP for use in Kubernetes manifests
output "mail_floating_ip" {
  value       = hcloud_floating_ip.mail.ip_address
  description = "Floating IP for Stalwart mail service"
}