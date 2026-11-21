variable "project" {
  description = "GCP project id (not the display name)."
  type        = string
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zones" {
  type    = list(string)
  default = ["europe-west1-b", "europe-west1-c", "europe-west1-d"]
}

variable "node_subnet_cidr" {
  type    = string
  default = "10.40.1.0/24"
}

variable "pods_cidr" {
  type    = string
  default = "10.44.0.0/14"
}

variable "services_cidr" {
  type    = string
  default = "10.48.0.0/20"
}

variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "min_nodes_per_zone" {
  type    = number
  default = 1
}

variable "max_nodes_per_zone" {
  type    = number
  default = 4
}

variable "enable_private_endpoint" {
  type    = bool
  default = false
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [{ cidr_block = "0.0.0.0/0", display_name = "anywhere (narrow this)" }]
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "db_tier" {
  description = "db-custom-1-3840 is 1 vCPU / 3.75 GiB; db-f1-micro is cheaper but not HA-capable."
  type        = string
  default     = "db-custom-1-3840"
}

variable "db_ha" {
  description = "REGIONAL creates a standby in another zone with automatic failover."
  type        = bool
  default     = true
}
