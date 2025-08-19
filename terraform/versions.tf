terraform {
  required_version = ">= 1.7.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.52.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.8.1"
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
