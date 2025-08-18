
# Variables
variable "hcloud_token" { default = "" }
variable "hcloud_image" { default = "" }
variable "cluster_name" { default = "mbrc" }
variable "hcloud_location" { default = "hel1" }
variable "cpn_count" { default = 1 }
variable "wkn_count" { default = 2 }
variable "sops_private_key" { default = "../age.agekey" }
variable "cpn_type" { default = "cpx21" }
variable "wkn_type" { default = "cx22" }
