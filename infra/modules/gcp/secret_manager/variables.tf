variable "project" {
  type = string
}

variable "secrets" {
  description = "Secret id -> value. Values are sensitive; `for_each` uses only the keys."
  type        = map(string)
  sensitive   = true
}

variable "accessors" {
  description = "Secret id -> list of IAM members that may read it."
  type        = map(list(string))
  default     = {}
}

variable "labels" {
  type    = map(string)
  default = {}
}
