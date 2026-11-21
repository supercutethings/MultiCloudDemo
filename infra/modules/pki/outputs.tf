# The secret-store contract. One flat map so an environment can write it as a single JSON
# document (AWS) or one secret per key (Azure, GCP) without knowing the module's internals.
#
#   server_ca            what callers verify the services with
#   <service>_cert       server leaf
#   <service>_key        server private key
#   <service>_client_ca  trust bundle of *allowed caller* CAs for that service
#   <client>_cert        client leaf for a caller identity
#   <client>_key         that caller's private key

locals {
  # Per-service bundle: only the CAs of identities the allow rule permits. With the default
  # rule this is the gateway CA alone; a second caller is one more entry in the bundle and
  # one more NetworkPolicy rule, which is what makes onboarding visible in review.
  client_ca_bundles = {
    for service in var.service_names : service => join(
      "\n",
      [
        for identity in lookup(var.allowed_clients, service, []) :
        tls_self_signed_cert.client_ca[identity].cert_pem
      ],
    )
  }
}

output "material" {
  description = "Everything a consumer needs, keyed as above. Sensitive: contains private keys."
  sensitive   = true

  value = merge(
    { server_ca = tls_self_signed_cert.server_ca.cert_pem },
    { for name in var.service_names : "${name}_cert" => tls_locally_signed_cert.server[name].cert_pem },
    { for name in var.service_names : "${name}_key" => tls_private_key.server[name].private_key_pem },
    { for name in var.service_names : "${name}_client_ca" => local.client_ca_bundles[name] },
    { for name in var.client_identities : "${name}_cert" => tls_locally_signed_cert.client[name].cert_pem },
    { for name in var.client_identities : "${name}_key" => tls_private_key.client[name].private_key_pem },
  )
}

output "server_ca_pem" {
  description = "Server CA certificate (public). Safe to hand to any client."
  value       = tls_self_signed_cert.server_ca.cert_pem
}

output "client_ca_pem" {
  description = "Per-identity client CA certificates (public)."
  value       = { for name in var.client_identities : name => tls_self_signed_cert.client_ca[name].cert_pem }
}
