terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.52.0"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.8.4"
    }

    talos = {
      source  = "siderolabs/talos"
      version = "0.8.1"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.38.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "3.0.2"
    }
  }
}




provider "hcloud" {
  token = var.hcloud_token
}

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "helm" {
}