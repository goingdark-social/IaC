output "kubeconfig_path" {
  value     = local_sensitive_file.kubeconfig.filename
  sensitive = true
}

output "lb_ip" {
  value = hcloud_load_balancer.main.ipv4
}
