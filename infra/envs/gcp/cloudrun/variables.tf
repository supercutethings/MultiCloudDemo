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

variable "connector_cidr" {
  description = "/28 for the Serverless VPC Access connector. Must not overlap the peering range."
  type        = string
  default     = "10.40.16.0/28"
}

variable "database_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "db_tier" {
  description = "db-f1-micro is the cheapest instance Cloud SQL will start; db-custom-1-3840 for real load."
  type        = string
  default     = "db-f1-micro"
}

variable "db_disk_size_gb" {
  type    = number
  default = 10
}

variable "db_ha" {
  description = "REGIONAL adds a standby in another zone. Roughly doubles the database line item."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "image_tag" {
  description = "Commit SHA or version pushed to Artifact Registry. Never `latest`."
  type        = string
  default     = "1.0.0"
}

variable "service_min_instances" {
  description = "0 means scale to zero and pay nothing while idle; the trade-off is a cold start."
  type        = number
  default     = 0
}

variable "service_max_instances" {
  type    = number
  default = 3
}

variable "gateway_min_instances" {
  description = "Keep one gateway warm so the public URL answers immediately after apply."
  type        = number
  default     = 1
}

variable "gateway_max_instances" {
  type    = number
  default = 10
}
