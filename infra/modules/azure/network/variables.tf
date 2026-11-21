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
  description = "VNet range. Passed to scripts/k8s-render.sh as VNET_CIDR on the Kubernetes leg."
  type        = string
  default     = "10.40.0.0/16"
}

variable "apps_subnet_cidr" {
  description = "Container Apps environment subnet. /23 minimum in practice: replicas consume addresses."
  type        = string
  default     = "10.40.0.0/23"
}

variable "data_subnet_cidr" {
  description = "Delegated subnet for PostgreSQL Flexible Server."
  type        = string
  default     = "10.40.4.0/24"
}

variable "endpoint_subnet_cidr" {
  description = "Private endpoints (Key Vault)."
  type        = string
  default     = "10.40.5.0/24"
}

variable "tags" {
  type    = map(string)
  default = {}
}
