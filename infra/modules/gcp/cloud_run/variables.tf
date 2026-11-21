variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "connector_id" {
  description = "Serverless VPC Access connector; every service sends egress through it."
  type        = string
}

variable "internal_callers" {
  description = "IAM members allowed to invoke the internal services, usually the gateway's service account."
  type        = list(string)
  default     = []
}

variable "services" {
  description = <<-EOT
    Service definitions keyed by name. `secret_env` maps an environment variable to a
    Secret Manager resource name; `upstreams` maps an environment variable to the key of an
    internal service in this same map, resolved to that service's real URI.
  EOT
  type = map(object({
    image           = string
    cpu             = number
    memory          = string
    min_instances   = number
    max_instances   = number
    port            = number
    public          = bool
    concurrency     = number
    service_account = string
    env             = map(string)
    secret_env      = map(string)
    upstreams       = map(string)
  }))
  default = {}
}

variable "labels" {
  type    = map(string)
  default = {}
}
