variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "name" {
  description = "Instance name. Lowercase, digits and hyphens."
  type        = string
}

variable "network_id" {
  description = "VPC the private range is peered into."
  type        = string
}

variable "database_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "user_name" {
  type    = string
  default = "app"
}

variable "password" {
  type      = string
  sensitive = true
}

variable "tier" {
  description = "db-f1-micro is the cheapest instance that Cloud SQL will still start."
  type        = string
  default     = "db-f1-micro"
}

variable "disk_size_gb" {
  type    = number
  default = 10
}

variable "ha" {
  description = "REGIONAL adds a standby in another zone with automatic failover."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "labels" {
  type    = map(string)
  default = {}
}
