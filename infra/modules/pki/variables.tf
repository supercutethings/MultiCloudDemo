variable "common_name" {
  description = "Prefix for the CA common names, e.g. showcase-dev-ca."
  type        = string
}

variable "service_names" {
  description = "Services that terminate mTLS (get a server certificate each)."
  type        = list(string)
  default     = ["auth", "catalog"]
}

variable "service_dns_names" {
  description = "Map of service name -> SAN list. Must include every name a client dials."
  type        = map(list(string))

  validation {
    condition     = alltrue([for name in var.service_names : contains(keys(var.service_dns_names), name)])
    error_message = "service_dns_names must have an entry for every service in service_names."
  }
}

variable "client_identities" {
  description = "Caller identities. Each gets its own issuing CA and one clientAuth leaf."
  type        = list(string)
  default     = ["gateway"]
}

variable "allowed_clients" {
  description = <<-EOT
    The allow rule: which caller identities each service accepts. The service is given a
    trust bundle containing only these CAs, so a caller whose issuer is absent is rejected
    during the TLS handshake. Defaults to the gateway for both services.
  EOT
  type        = map(list(string))
  default = {
    auth    = ["gateway"]
    catalog = ["gateway"]
  }

  validation {
    condition     = alltrue([for service in keys(var.allowed_clients) : contains(var.service_names, service)])
    error_message = "allowed_clients keys must all appear in service_names."
  }

  validation {
    condition = alltrue([
      for service, identities in var.allowed_clients : alltrue([
        for identity in identities : contains(var.client_identities, identity)
      ])
    ])
    error_message = "Every identity in allowed_clients must exist in client_identities."
  }
}

variable "validity_hours" {
  description = "Leaf certificate lifetime. 2160h = 90 days."
  type        = number
  default     = 2160
}

variable "ca_validity_hours" {
  description = "CA lifetime. 87600h = 10 years."
  type        = number
  default     = 87600
}
