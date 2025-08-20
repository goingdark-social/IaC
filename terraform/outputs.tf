output "kubeconfig_path" {
  value     = local_sensitive_file.kubeconfig.filename
  sensitive = true
}

output "lb_ip" {
  value = hcloud_load_balancer.main.ipv4
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
