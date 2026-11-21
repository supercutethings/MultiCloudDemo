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

variable "tenant_id" {
  type = string
}

variable "name_suffix" {
  description = "Short random suffix; vault names are globally unique."
  type        = string
  default     = ""
}

variable "vnet_id" {
  description = "VNet linked to the privatelink zone."
  type        = string
}

variable "endpoint_subnet_id" {
  description = "Subnet that hosts the private endpoint."
  type        = string
}

variable "deployer_object_id" {
  description = "Object id of the identity running Terraform, granted Secrets Officer."
  type        = string
}

variable "public_network_access_enabled" {
  description = "Keep true so a laptop or CI can seed secrets; the data path still prefers the private endpoint."
  type        = bool
  default     = true
}

variable "allowed_ip_ranges" {
  description = "CIDRs allowed to reach the public endpoint. Empty means Allow (fresh-clone friendly)."
  type        = list(string)
  default     = []
}

variable "purge_protection_enabled" {
  description = "Irreversible once on; enable for prod only, otherwise destroy leaves the name taken."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
