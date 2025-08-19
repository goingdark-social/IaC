variable "api_server_host"  { type = string }
variable "client_cert_b64"  { type = string }
variable "client_key_b64"   { type = string }
variable "ca_cert_b64"      { type = string }

variable "hcloud_token"     { type = string }
variable "hcloud_image"     { type = string }
variable "hcloud_network_id"{ type = string }

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = "1.18.1"
  values     = [file("${path.root}/manifests/cilium.yaml")]
}

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
  depends_on = [helm_release.cilium]
}

resource "kubernetes_namespace" "base-system" {
  metadata { name = "base-system" }
  depends_on = [helm_release.cilium]
}

resource "kubernetes_secret" "hcloud" {
  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }
  data = {
    token   = var.hcloud_token
    image   = var.hcloud_image
    network = var.hcloud_network_id
  }
  depends_on = [helm_release.cilium]
}
