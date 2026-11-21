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

variable "vnet_id" {
  description = "VNet the private DNS zone is linked to."
  type        = string
}

variable "delegated_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers."
  type        = string
}

variable "name_suffix" {
  description = "Short random suffix; server names are globally unique."
  type        = string
  default     = ""
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "sku_name" {
  description = "B_Standard_B1ms is the cheap burstable; GP_Standard_D2ds_v5 for real load."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "ha" {
  description = "Zone-redundant standby. Roughly doubles the database line item."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "admin_login" {
  type    = string
  default = "showcase"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "tags" {
  type    = map(string)
  default = {}
}
