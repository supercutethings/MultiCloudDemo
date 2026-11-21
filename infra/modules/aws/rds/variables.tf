variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the DB subnet group (at least two AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group allowing 5432 from the application tiers."
  type        = string
}

variable "instance_class" {
  description = "t4g.micro is the cheapest realistic dev size (~$12/month)."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "db_username" {
  type    = string
  default = "app"
}

variable "engine_version" {
  description = "Major PostgreSQL version; minor upgrades are automatic."
  type        = string
  default     = "16"
}

variable "multi_az" {
  description = "Multi-AZ doubles the cost; false is correct for demo environments."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  description = "Disable only in ephemeral environments where `make destroy` must work."
  type        = bool
  default     = false
}

variable "performance_insights" {
  description = "Costs extra; useful from staging upwards."
  type        = bool
  default     = false
}
