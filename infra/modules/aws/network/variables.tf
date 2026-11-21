variable "project" {
  description = "Short project slug used as a name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across (2 keeps cost down)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so private tasks can pull images. Costs ~$33/month."
  type        = bool
  default     = true
}

variable "nat_gateway_per_az" {
  description = "One NAT per AZ (HA, ~$33/month each) instead of a single shared NAT."
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "EKS cluster name; adds the subnet tags the load balancer controller needs."
  type        = string
  default     = null
}

variable "container_port" {
  description = "Port the application containers listen on."
  type        = number
  default     = 8000
}

variable "internal_port" {
  description = "Port the gateway uses to reach auth and catalog (mutual TLS, 8443)."
  type        = number
  default     = 8443
}
