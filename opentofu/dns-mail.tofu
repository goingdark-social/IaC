# Stalwart Mail Server DNS Configuration

# Stalwart Mail Server DNS Configuration

variable "dkim_ed25519_key" {
  description = "DKIM Ed25519 public key for Stalwart mail server"
  type        = string
  default     = "N/BkJD6xbEiMb39v7JW6AwdPHO5gKB3fcCnod4zQ31U="
  sensitive   = true
}

variable "dkim_rsa_key" {
  description = "DKIM RSA public key for Stalwart mail server"
  type        = string
  default     = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqlddLN3BjInvBqI1KpdouG7feBsEt5t233jWQJW7FaY7sR/MfWNxuzTObLoZ3l76DFq3xPjVhmy/YYiOAnMOtq9hUFqgBVTSwUNHYPz1YUEcrI5+Ban7P7LV8kggvTAaWhAI3iSXJIFaUq78K8YYr/zrGyBlg5HCPpd+DMRAB8j1ID8bcWFaVebwAOrartXOO/f8Bn9jrRrLhjP3c8UlmkJLXkSncXPp69R9VpevrKJtpBjaFxKtx7DXGie821MHuWJ7pWMdU1Uf3z8UBKF9bnrCZ5v0SdiaFkPXR1Iiq/gR6bMwdlWvST9V6ePnqZqX+Iv4FA28byOot73/CIINFwIDAQAB"
  sensitive   = true
}

variable "mta_sts_policy_id" {
  description = "MTA-STS policy ID"
  type        = string
  default     = "16561011793845132961"
}

variable "tlsa_certificate_hash" {
  description = "TLSA certificate hash"
  type        = string
  default     = "064dbc632f1ba7d0a2a3faeadeedfebd6f90f850dfb852c97ee9df9b6e5c5e7c"
}

data "hcloud_load_balancer" "worker_lb" {
  name = var.stalwart_mail_loadbalancer_name
}

locals {
  worker_load_balancer_id = data.hcloud_load_balancer.worker_lb.id
  worker_load_balancer_ipv4 = data.hcloud_load_balancer.worker_lb.ipv4
  worker_load_balancer_ipv6 = data.hcloud_load_balancer.worker_lb.ipv6

  dns_records = {
    "mail_a" = {
      name    = "mail"
      type    = "A"
      content = local.worker_load_balancer_ipv4
      comment = "Stalwart mail server"
    }
    "smtp_a" = {
      name    = "smtp"
      type    = "A"
      content = local.worker_load_balancer_ipv4
      comment = "Stalwart SMTP"
    }
    "imap_a" = {
      name    = "imap"
      type    = "A"
      content = local.worker_load_balancer_ipv4
      comment = "Stalwart IMAP"
    }
    "mail_aaaa" = {
      name    = "mail"
      type    = "AAAA"
      content = local.worker_load_balancer_ipv6
      comment = "Stalwart mail server IPv6"
    }
    "smtp_aaaa" = {
      name    = "smtp"
      type    = "AAAA"
      content = local.worker_load_balancer_ipv6
      comment = "Stalwart SMTP IPv6"
    }
    "imap_aaaa" = {
      name    = "imap"
      type    = "AAAA"
      content = local.worker_load_balancer_ipv6
      comment = "Stalwart IMAP IPv6"
    }
    "mx_apex" = {
      name     = "@"
      type     = "MX"
      content  = "mail.peekoff.com"
      priority = 10
      comment  = "Mail exchange for peekoff.com"
    }
    "spf_apex" = {
      name    = "@"
      type    = "TXT"
      content = "\"v=spf1 mx -all\""
      comment = "SPF record for peekoff.com"
    }
    "dmarc" = {
      name    = "_dmarc"
      type    = "TXT"
      content = "\"v=DMARC1; p=reject; rua=mailto:postmaster@peekoff.com\""
      comment = "DMARC record for peekoff.com"
    }
    "dkim_ed25519" = {
      name    = "202404e._domainkey"
      type    = "TXT"
      content = "\"v=DKIM1; k=ed25519; h=sha256; p=${var.dkim_ed25519_key}\""
      comment = "DKIM Ed25519 key for peekoff.com"
    }
    "dkim_rsa" = {
      name    = "202404r._domainkey"
      type    = "TXT"
      content = "\"v=DKIM1; k=rsa; h=sha256; p=${var.dkim_rsa_key}\""
      comment = "DKIM RSA key for peekoff.com"
    }
    "mta_sts_cname" = {
      name    = "mta-sts"
      type    = "CNAME"
      content = "mail.peekoff.com"
      comment = "MTA-STS CNAME for peekoff.com"
    }
    "mta_sts_txt" = {
      name    = "_mta-sts"
      type    = "TXT"
      content = "\"v=STSv1; id=${var.mta_sts_policy_id}\""
      comment = "MTA-STS policy for peekoff.com"
    }
    "tls_rpt" = {
      name    = "_smtp._tls"
      type    = "TXT"
      content = "\"v=TLSRPTv1; rua=mailto:postmaster@peekoff.com\""
      comment = "TLS reporting for peekoff.com"
    }
    "autoconfig_cname" = {
      name    = "autoconfig"
      type    = "CNAME"
      content = "mail.peekoff.com"
      comment = "Autoconfiguration CNAME for peekoff.com"
    }
    "autodiscover_cname" = {
      name    = "autodiscover"
      type    = "CNAME"
      content = "mail.peekoff.com"
      comment = "Autodiscover CNAME for peekoff.com"
    }
    "srv_imap_tcp" = {
      name    = "_imap._tcp"
      type    = "SRV"
      content = "0 1 143 mail.peekoff.com"
      comment = "IMAP SRV record for peekoff.com"
    }
    "srv_imaps_tcp" = {
      name    = "_imaps._tcp"
      type    = "SRV"
      content = "0 1 993 mail.peekoff.com"
      comment = "IMAPS SRV record for peekoff.com"
    }
    "srv_submission_tcp" = {
      name    = "_submission._tcp"
      type    = "SRV"
      content = "0 1 587 mail.peekoff.com"
      comment = "SMTP submission SRV record for peekoff.com"
    }
    "srv_submissions_tcp" = {
      name    = "_submissions._tcp"
      type    = "SRV"
      content = "0 1 465 mail.peekoff.com"
      comment = "SMTP submissions SRV record for peekoff.com"
    }
    "tlsa_25_tcp" = {
      name    = "_25._tcp.mail"
      type    = "TLSA"
      content = "3 0 1 ${var.tlsa_certificate_hash}"
      comment = "TLSA record for mail.peekoff.com port 25"
    }
  }
}

data "cloudflare_zone" "peekoff" {
  filter = {
    name = var.cloudflare_zone_name
  }
}

resource "cloudflare_dns_record" "records" {
  for_each = local.dns_records

  zone_id  = data.cloudflare_zone.peekoff.id
  name     = each.value.name
  content  = each.value.content
  type     = each.value.type
  priority = each.value.priority
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  comment  = each.value.comment
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
    for k, v in cloudflare_dns_record.records : k => {
      name    = v.name
      type    = v.type
      content = v.content
    }
  }
}