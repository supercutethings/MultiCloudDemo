variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "resource_group_name" {
  type = string
}

variable "vnet_cidr" {
  description = "VNet range (passed to scripts/k8s-render.sh as VNET_CIDR)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "node_subnet_cidr" {
  type    = string
  default = "10.30.1.0/24"
}

variable "data_subnet_cidr" {
  type    = string
  default = "10.30.2.0/24"
}

variable "endpoint_subnet_cidr" {
  description = "Subnet for private endpoints (Key Vault)."
  type        = string
  default     = "10.30.4.0/24"
}

variable "appgw_subnet_cidr" {
  description = "Dedicated subnet for the managed Application Gateway."
  type        = string
  default     = "10.30.3.0/24"
}

variable "pod_cidr" {
  description = "Overlay CIDR for pods; must not overlap the VNet."
  type        = string
  default     = "10.244.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "sku_tier" {
  description = "Free has no uptime SLA; Standard buys a financially-backed SLA and a longer API-server retention."
  type        = string
  default     = "Free"
}

variable "node_vm_size" {
  description = "2 vCPU / 8 GiB. Small enough for three zones to stay affordable."
  type        = string
  default     = "Standard_B2s"
}

variable "node_min_count" {
  description = "One per zone when zone_redundant is true."
  type        = number
  default     = 3
}

variable "node_max_count" {
  type    = number
  default = 12
}

variable "zone_redundant" {
  description = "Spread the node pool across zones 1/2/3."
  type        = bool
  default     = true
}

variable "private_cluster_enabled" {
  type    = bool
  default = false
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach a public API server. Empty means no restriction."
  type        = list(string)
  default     = []
}

variable "enable_defender" {
  description = "Microsoft Defender for Containers (paid). Off for the demo."
  type        = bool
  default     = false
}

variable "name_suffix" {
  description = "Short random suffix for globally unique names (registry)."
  type        = string
  default     = ""
}

variable "acr_sku" {
  type    = string
  default = "Basic"
}

variable "tags" {
  type    = map(string)
  default = {}
}
