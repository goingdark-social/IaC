# Stalwart Mail Server DNS Configuration

data "hcloud_load_balancer" "worker_lb" {
  name = var.stalwart_mail_loadbalancer_name
}

locals {
  worker_load_balancer_id = data.hcloud_load_balancer.worker_lb.id
  worker_load_balancer_ipv4 = data.hcloud_load_balancer.worker_lb.ipv4
  worker_load_balancer_ipv6 = data.hcloud_load_balancer.worker_lb.ipv6
}

data "cloudflare_zone" "peekoff" {
  filter = {
    name = var.cloudflare_zone_name
  }
}

resource "cloudflare_dns_record" "mail_a" {
  zone_id = data.cloudflare_zone.peekoff.id
  name    = "mail"
  content = local.worker_load_balancer_ipv4
  type    = "A"
  ttl     = 300
  proxied = false
  comment = "Stalwart mail server"
}

resource "cloudflare_dns_record" "smtp_a" {
  zone_id = data.cloudflare_zone.peekoff.id
  name    = "smtp"
  content = local.worker_load_balancer_ipv4
  type    = "A"
  ttl     = 300
  proxied = false
  comment = "Stalwart SMTP"
}

resource "cloudflare_dns_record" "imap_a" {
  zone_id = data.cloudflare_zone.peekoff.id
  name    = "imap"
  content = local.worker_load_balancer_ipv4
  type    = "A"
  ttl     = 300
  proxied = false
  comment = "Stalwart IMAP"
}

resource "cloudflare_dns_record" "mail_aaaa" {
  zone_id = data.cloudflare_zone.peekoff.id
  name    = "mail"
  content = local.worker_load_balancer_ipv6
  type    = "AAAA"
  ttl     = 300
  proxied = false
  comment = "Stalwart mail server IPv6"
}

resource "cloudflare_dns_record" "smtp_aaaa" {
  zone_id = data.cloudflare_zone.peekoff.id
  name    = "smtp"
  content = local.worker_load_balancer_ipv6
  type    = "AAAA"
  ttl     = 300
  proxied = false
  comment = "Stalwart SMTP IPv6"
}

resource "cloudflare_dns_record" "imap_aaaa" {
  zone_id = data.cloudflare_zone.peekoff.id
  name    = "imap"
  content = local.worker_load_balancer_ipv6
  type    = "AAAA"
  ttl     = 300
  proxied = false
  comment = "Stalwart IMAP IPv6"
}

resource "hcloud_rdns" "stalwart_mail_ipv4" {
  load_balancer_id = local.worker_load_balancer_id
  ip_address       = local.worker_load_balancer_ipv4
  dns_ptr          = "mail.peekoff.com"
}

resource "hcloud_rdns" "stalwart_mail_ipv6" {
  load_balancer_id = local.worker_load_balancer_id
  ip_address       = local.worker_load_balancer_ipv6
  dns_ptr          = "mail.peekoff.com"
}

output "stalwart_mail_ipv4" {
  description = "Stalwart mail server IPv4 address"
  value       = local.worker_load_balancer_ipv4
}

output "stalwart_mail_ipv6" {
  description = "Stalwart mail server IPv6 address"
  value       = local.worker_load_balancer_ipv6
}

output "stalwart_mail_dns_records" {
  description = "DNS records created for Stalwart mail server"
  value = {
    mail_a_record    = cloudflare_dns_record.mail_a.name
    reverse_dns_ipv4 = hcloud_rdns.stalwart_mail_ipv4.dns_ptr
    reverse_dns_ipv6 = hcloud_rdns.stalwart_mail_ipv6.dns_ptr
  }
}