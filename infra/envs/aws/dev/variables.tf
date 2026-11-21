variable "region" {
  description = "AWS region. Keep it close to you; latency and price both vary."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Short project slug; prefixes every resource name."
  type        = string
  default     = "showcase"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "image_tag" {
  description = "Image tag deployed to every service. CI passes the commit SHA; never `latest`."
  type        = string
  default     = "bootstrap"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "az_count" {
  description = "Availability zones to spread subnets across. 2 is the cost/availability compromise."
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "~$34/month. Required for private tasks to pull images from ECR."
  type        = bool
  default     = true
}

variable "container_insights" {
  description = "CloudWatch Container Insights. Off by default because it is billed per metric."
  type        = bool
  default     = false
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Doubles RDS cost; false for demo environments."
  type        = bool
  default     = false
}

variable "service_cpu" {
  description = "Fargate CPU units per task (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "service_memory" {
  description = "Fargate memory in MiB per task."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Replicas per service. 2 makes the rolling deploy observable, 1 is cheaper."
  type        = number
  default     = 1
}

variable "enable_gateway_autoscaling" {
  description = "Target-tracking autoscaling on the gateway. Costs nothing while idle."
  type        = bool
  default     = true
}

variable "gateway_max_replicas" {
  type    = number
  default = 3
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. Null keeps the listener on HTTP (bare ALB DNS name)."
  type        = string
  default     = null
}
