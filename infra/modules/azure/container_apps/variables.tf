variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "resource_group_name" {
  type = string
}

variable "infrastructure_subnet_id" {
  description = "Subnet delegated to Microsoft.App/environments."
  type        = string
}

variable "registry_id" {
  description = "ACR resource id; every app identity gets AcrPull on it."
  type        = string
}

variable "registry_login_server" {
  description = "ACR host used in the image reference and the registry block."
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault resource id; every app identity gets Key Vault Secrets User on it."
  type        = string
}

variable "probe_port" {
  description = "Port the health probes hit. Plaintext ops surface, not the data port."
  type        = number
  default     = 8000
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "apps" {
  description = <<-EOT
    Service definitions keyed by name. `secrets` maps an environment variable to a Key
    Vault secret URI; `upstreams` maps an environment variable to the key of an internal
    app in this same map, resolved to that app's real FQDN.
  EOT
  type = map(object({
    image        = string
    cpu          = number
    memory       = string
    min_replicas = number
    max_replicas = number
    external     = bool
    target_port  = number
    env          = map(string)
    secrets      = map(string)
    upstreams    = map(string)
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
