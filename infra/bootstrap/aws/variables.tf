variable "region" {
  description = "AWS region for the state backend and CI role."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Short project slug, used as a prefix for every resource name."
  type        = string
  default     = "showcase"
}

variable "github_org" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name (without the owner)."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false when the account already has one."
  type        = bool
  default     = true
}

variable "budget_alert_email" {
  description = "Email for the monthly budget alarm. Empty string disables the alarm."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly budget threshold in USD."
  type        = number
  default     = 25
}
