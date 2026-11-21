variable "project" {
  type    = string
  default = "showcase"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "vnet_cidr" {
  type    = string
  default = "10.30.0.0/16"
}

variable "node_subnet_cidr" {
  type    = string
  default = "10.30.1.0/24"
}

variable "data_subnet_cidr" {
  type    = string
  default = "10.30.2.0/24"
}

variable "appgw_subnet_cidr" {
  type    = string
  default = "10.30.3.0/24"
}

variable "endpoint_subnet_cidr" {
  type    = string
  default = "10.30.4.0/24"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "node_min_count" {
  type    = number
  default = 3
}

variable "node_max_count" {
  type    = number
  default = 12
}

variable "zone_redundant" {
  type    = bool
  default = true
}

variable "private_cluster_enabled" {
  type    = bool
  default = false
}

variable "api_server_authorized_ip_ranges" {
  type    = list(string)
  default = []
}

variable "enable_defender" {
  type    = bool
  default = false
}

variable "acr_sku" {
  type    = string
  default = "Basic"
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "db_admin_login" {
  type    = string
  default = "showcase"
}

variable "db_sku" {
  description = "B_Standard_B1ms is the cheap burstable; GP_Standard_D2ds_v5 for real load."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  type    = number
  default = 32768
}

variable "db_ha" {
  description = "Zone-redundant Flexible Server with a standby in another zone."
  type        = bool
  default     = true
}

variable "key_vault_admin_ip_ranges" {
  description = "CIDRs allowed to reach the vault's public endpoint (your laptop/CI egress)."
  type        = list(string)
  default     = []
}
