# Private PKI for the internal mTLS links on the serverless (ECS) path.
#
# Two trust domains, one CA each:
#
#   * the **server CA** signs what auth and catalog present; the gateway trusts it;
#   * **one client CA per caller identity** signs what a caller presents; a service is
#     handed the bundle of client CAs it accepts and nothing else.
#
# Why per-identity client CAs instead of "one CA, check the subject": uvicorn does not
# expose the peer certificate to the ASGI app (verified against 0.32.1), so the only place
# to answer "is this caller allowed?" is the handshake. Binding each identity to its own
# issuer means the answer is a verifiable chain -- a second leaf under the same CA cannot
# be minted by anyone who should not already have one, and onboarding a service is an
# explicit allow rule (`allowed_clients`) rather than a side effect of issuance.
#
# Why not ACM Private CA / Key Vault Certificate / CAS: all three are the right product for
# a company and all three cost real money per certificate or per month. This produces the
# same hierarchy with the free `tls` provider. The CA keys exist only in Terraform state
# (encrypted remote backend) and the provider secret manager; they are never mounted into
# a workload, so a compromised pod cannot mint a new identity.
#
# Rotation on this path is a deliberate Terraform operation:
#   terraform apply -replace=module.pki.tls_private_key.server_ca   # re-issues server leaves
#   terraform apply -replace=module.pki.tls_private_key.client_ca    # re-issues caller leaves
# On Kubernetes the same hierarchy is issued and rotated by cert-manager instead -- see
# k8s/components/internal-pki and docs/kubernetes.md.

terraform {
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# --- Trust domain 1: what the services present ----------------------------------------

resource "tls_private_key" "server_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "server_ca" {
  private_key_pem = tls_private_key.server_ca.private_key_pem

  subject {
    common_name  = "${var.common_name}-server-ca"
    organization = "Showcase Platform"
  }

  is_ca_certificate     = true
  validity_period_hours = var.ca_validity_hours
  early_renewal_hours   = 0

  allowed_uses = ["cert_signing", "crl_signing"]
}

# --- Trust domain 2: one issuing CA per caller identity --------------------------------

resource "tls_private_key" "client_ca" {
  for_each = toset(var.client_identities)

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "client_ca" {
  for_each = toset(var.client_identities)

  private_key_pem = tls_private_key.client_ca[each.key].private_key_pem

  subject {
    common_name  = "${var.common_name}-${each.key}-client-ca"
    organization = "Showcase Platform"
  }

  is_ca_certificate     = true
  validity_period_hours = var.ca_validity_hours
  early_renewal_hours   = 0

  allowed_uses = ["cert_signing", "crl_signing"]
}

# --- Server identities (auth, catalog) -------------------------------------------------
# SANs must contain every name a caller actually dials: the short Service name, the
# namespace-qualified name, and localhost for local/port-forward debugging. A missing SAN
# is a handshake failure at the worst possible moment, so it is an explicit input.

resource "tls_private_key" "server" {
  for_each = toset(var.service_names)

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  for_each = toset(var.service_names)

  private_key_pem = tls_private_key.server[each.key].private_key_pem

  subject {
    common_name  = each.key
    organization = "Showcase Platform"
  }

  dns_names = var.service_dns_names[each.key]
}

resource "tls_locally_signed_cert" "server" {
  for_each = toset(var.service_names)

  cert_request_pem   = tls_cert_request.server[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.server_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.server_ca.cert_pem

  validity_period_hours = var.validity_hours
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

# --- Caller identities (one leaf per client, signed by its own CA) ---------------------
# client_auth only: none of these certificates can be used to impersonate a server.

resource "tls_private_key" "client" {
  for_each = toset(var.client_identities)

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  for_each = toset(var.client_identities)

  private_key_pem = tls_private_key.client[each.key].private_key_pem

  subject {
    common_name  = each.key
    organization = "Showcase Platform"
  }
}

resource "tls_locally_signed_cert" "client" {
  for_each = toset(var.client_identities)

  cert_request_pem   = tls_cert_request.client[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.client_ca[each.key].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.client_ca[each.key].cert_pem

  validity_period_hours = var.validity_hours
  allowed_uses          = ["client_auth", "digital_signature"]
}
