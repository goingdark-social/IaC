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
    local = {
      source  = "hashicorp/local"
      version = "2.5.1"
    }

  }
}


provider "hcloud" {
  token = var.hcloud_token
}



provider "kubernetes" {
  alias       = "addons"
  config_path = local_sensitive_file.kubeconfig.filename
}

provider "helm" {
  alias = "addons"
  kubernetes = {
    config_path = local_sensitive_file.kubeconfig.filename
  }
}

