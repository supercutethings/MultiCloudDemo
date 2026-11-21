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

variable "name_suffix" {
  description = "Short random suffix; the registry name is globally unique."
  type        = string
  default     = ""
}

variable "sku" {
  description = "Basic is enough for three images; Premium buys geo-replication and private link."
  type        = string
  default     = "Basic"
}

variable "tags" {
  type    = map(string)
  default = {}
}
