variable "name" {
  description = "Service name; also the container name and Cloud Map record."
  type        = string
}

variable "name_prefix" {
  description = "Environment-wide prefix, e.g. showcase-dev."
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  description = "Needed by the autoscaling target resource id."
  type        = string
}

variable "image" {
  description = "Full image reference, pinned by tag or digest."
  type        = string
}

variable "cpu" {
  description = "Fargate CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "environment_variables" {
  description = "Non-secret configuration, injected as the container environment."
  type        = map(string)
  default     = {}
}

variable "secret_environment_variables" {
  description = "Env var name -> Secrets Manager reference (arn:json-key::)."
  type        = map(string)
  default     = {}
}

variable "execution_role_arn" {
  description = "Shared ECS execution role (image pulls + secret resolution)."
  type        = string
}

variable "task_role_policy_json" {
  description = "Optional inline policy for the per-service task role."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "create_target_group" {
  description = "True for the only internet-facing service (the gateway)."
  type        = bool
  default     = false
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "alb_listener_arn" {
  description = "Listener that forwards to this service's target group."
  type        = string
  default     = null
}

variable "listener_rule_priority" {
  type    = number
  default = 100
}

variable "target_group_health_check_path" {
  description = "Readiness path for LB health checks: never /healthz."
  type        = string
  default     = "/readyz"
}

variable "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace; null disables registration."
  type        = string
  default     = null
}

variable "service_discovery_namespace_name" {
  type    = string
  default = null
}

variable "enable_autoscaling" {
  type    = bool
  default = false
}

variable "min_replicas" {
  type    = number
  default = 1
}

variable "max_replicas" {
  type    = number
  default = 4
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "additional_ports" {
  description = "Extra container ports to publish, e.g. the plaintext ops port."
  type        = list(number)
  default     = []
}

variable "health_check_port" {
  description = "Port the task health check probes. Defaults to container_port; set it to the ops port when the data port is mTLS-only."
  type        = number
  default     = null
}
