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
  default = "10.40.0.0/16"
}

variable "apps_subnet_cidr" {
  type    = string
  default = "10.40.0.0/23"
}

variable "data_subnet_cidr" {
  type    = string
  default = "10.40.4.0/24"
}

variable "endpoint_subnet_cidr" {
  type    = string
  default = "10.40.5.0/24"
}

variable "acr_sku" {
  type    = string
  default = "Basic"
}

variable "postgres_version" {
  type    = string
  default = "16"
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
  description = "Zone-redundant standby. Roughly doubles the database line item."
  type        = bool
  default     = false
}

variable "db_admin_login" {
  type    = string
  default = "showcase"
}

variable "image_tag" {
  description = "Commit SHA or version pushed to ACR. Never `latest`."
  type        = string
  default     = "1.0.0"
}

variable "service_min_replicas" {
  description = "0 means scale to zero and pay nothing while idle; the trade-off is a cold start."
  type        = number
  default     = 0
}

variable "service_max_replicas" {
  type    = number
  default = 3
}

variable "gateway_min_replicas" {
  description = "Keep one gateway warm so the public URL answers immediately after apply."
  type        = number
  default     = 1
}

variable "gateway_max_replicas" {
  type    = number
  default = 10
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "key_vault_allowed_ip_ranges" {
  description = "CIDRs allowed to reach the vault's public endpoint. Empty means Allow (fresh-clone friendly)."
  type        = list(string)
  default     = []
}
