variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "repositories" {
  description = "One ECR repository per service."
  type        = list(string)
  default     = ["auth", "catalog", "gateway"]
}

variable "keep_last_images" {
  description = "Number of images kept per repository before the lifecycle policy expires them."
  type        = number
  default     = 10
}
