variable "hcloud_token"    { type = string }
variable "hcloud_image"    { type = string }
variable "cluster_name"    {
    type = string
    default = "mbrc"
    }
variable "hcloud_location" { 
    type = string
    default = "hel1"
}
variable "cpn_count"       {
     type = number  
     default = 3
}
variable "wkn_count"       {
    type = number
    default = 0
}

variable "kubeconfig_path" {
  type    = string
  default = ""
}