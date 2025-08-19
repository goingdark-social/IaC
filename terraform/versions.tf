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
  host                   = local.kcfg.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kcfg.clusters[0].cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kcfg.users[0].user["client-certificate-data"])
  client_key             = base64decode(local.kcfg.users[0].user["client-key-data"])
}

provider "helm" {
  kubernetes = {
    host                   = local.kcfg.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kcfg.clusters[0].cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kcfg.users[0].user["client-certificate-data"])
    client_key             = base64decode(local.kcfg.users[0].user["client-key-data"])
  }
}
