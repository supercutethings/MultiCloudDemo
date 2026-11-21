variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "showcase"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  description = "VPC range. Must match the VPC_CIDR passed to scripts/k8s-render.sh."
  type        = string
  default     = "10.20.0.0/16"
}

variable "owner" {
  description = "Tag value for cost attribution."
  type        = string
  default     = "platform"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  description = "ARM instances: cheaper, and the images are architecture-independent Python."
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "node_min_size" {
  description = "One node per AZ. Below this, losing a zone means losing capacity you cannot replace."
  type        = number
  default     = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  description = "Autoscaler ceiling. 12 x t4g.medium is the blast radius of a runaway load test."
  type        = number
  default     = 12
}

variable "enable_spot_pool" {
  type    = bool
  default = false
}

variable "endpoint_public_access" {
  description = "false gives a fully private API endpoint (requires a bastion or VPN)."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Restrict the public API endpoint. 0.0.0.0/0 is the demo default; narrow it for real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Zone-redundant database with automatic failover. Costs double; on by default in the HA stack."
  type        = bool
  default     = true
}
