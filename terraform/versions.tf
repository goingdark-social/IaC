
terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.44.1"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.17.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.3.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.27.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.11.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "kubernetes" {
  host                   = try(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host, null)
  client_certificate     = try(base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate), null)
  client_key             = try(base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key), null)
  cluster_ca_certificate = try(base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate), null)
}

provider "helm" {
  kubernetes {
    host                   = try(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host, null)
    client_certificate     = try(base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate), null)
    client_key             = try(base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key), null)
    cluster_ca_certificate = try(base64decode(data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate), null)
  }
}
