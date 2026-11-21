variable "project" {
  description = "GCP project id (not the display name)."
  type        = string
}

variable "region" {
  type = string
}

variable "name" {
  description = "VPC name."
  type        = string
}

variable "connector_name" {
  description = "Serverless VPC Access connector name. GCP caps this at 25 characters."
  type        = string

  validation {
    condition     = length(var.connector_name) <= 25
    error_message = "The connector name must be 25 characters or fewer."
  }
}

variable "connector_cidr" {
  description = "/28 reserved for the connector. Cloud Run has no VPC route without it."
  type        = string
  default     = "10.40.16.0/28"

  validation {
    condition     = can(cidrnetmask(var.connector_cidr)) && endswith(var.connector_cidr, "/28")
    error_message = "The connector range must be a /28, because that is the only size GCP accepts."
  }
}

variable "connector_min_instances" {
  type    = number
  default = 2
}

variable "connector_max_instances" {
  type    = number
  default = 3
}

variable "labels" {
  type    = map(string)
  default = {}
}
