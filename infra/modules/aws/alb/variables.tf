variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "target_group_arn" {
  description = "Target group of the only public service (gateway)."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN. Null means HTTP-only (local demos, no domain)."
  type        = string
  default     = null
}

variable "idle_timeout" {
  type    = number
  default = 60
}
