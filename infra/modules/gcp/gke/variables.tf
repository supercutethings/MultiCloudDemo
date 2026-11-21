variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "region" {
  description = "Regional cluster location; also the zone group for the control plane."
  type        = string
  default     = "europe-west1"
}

variable "zones" {
  description = "Node locations. Three zones, one node minimum each, is the HA baseline."
  type        = list(string)
  default     = ["europe-west1-b", "europe-west1-c", "europe-west1-d"]
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "pods_range_name" {
  type    = string
  default = "pods"
}

variable "services_range_name" {
  type    = string
  default = "services"
}

variable "kubernetes_version" {
  description = "Null follows the release channel; pin it only when you mean to."
  type        = string
  default     = null
}

variable "release_channel" {
  type    = string
  default = "REGULAR"
}

variable "machine_type" {
  description = "e2-standard-2: 2 vCPU / 8 GiB, the cheapest sensible GKE node."
  type        = string
  default     = "e2-standard-2"
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
  description = "True makes the API server reachable only from the VPC (needs a bastion/VPN)."
  type        = bool
  default     = false
}

variable "master_ipv4_cidr_block" {
  type    = string
  default = "172.16.0.0/28"
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the public API endpoint."
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

variable "labels" {
  type    = map(string)
  default = {}
}
