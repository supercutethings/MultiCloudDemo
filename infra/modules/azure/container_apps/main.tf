# Container Apps runtime for the serverless leg.
#
# One environment, three apps, and one user-assigned identity per app. The identity is the
# Azure answer to the ECS task role: it pulls from ACR (AcrPull) and reads exactly the
# secrets this app needs (Key Vault Secrets User). No registry password and no connection
# string ever reaches the container definition as plain configuration.
#
# Two resources instead of one, on purpose: `internal` apps are created first so that the
# `public` apps can point at their real FQDNs. The FQDN is a computed attribute of the app
# (`ingress[0].fqdn`), so referencing it is more reliable than assembling
# `<name>.<default-domain>` by hand and hoping the environment agrees.
#
# A note on the trust model, because it is the one place this leg differs from ECS and
# Kubernetes: Container Apps ingress terminates TLS and forwards plaintext to the
# container, and internal ingress offers no client-certificate passthrough. So the
# gateway -> auth/catalog hop is plain HTTP *inside* the environment, which is not
# internet-reachable. The application-level mTLS from ADR 0005 still applies on ECS and
# Kubernetes; the gap is recorded in docs/cloud-matrix.md rather than hidden.

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "multicloud-iac-showcase"
    },
    var.tags,
  )

  internal_apps = { for name, app in var.apps : name => app if !app.external }
  public_apps   = { for name, app in var.apps : name => app if app.external }

  # Plain configuration plus secret references, in the shape the provider wants.
  internal_env = {
    for name, app in local.internal_apps : name => concat(
      [for key, value in app.env : { name = key, value = value, secret_name = null }],
      [for key, _ in app.secrets : { name = key, value = null, secret_name = key }],
    )
  }

  # Public apps additionally resolve their upstreams to the internal apps' real FQDNs.
  public_env = {
    for name, app in local.public_apps : name => concat(
      [for key, value in app.env : { name = key, value = value, secret_name = null }],
      [for key, _ in app.secrets : { name = key, value = null, secret_name = key }],
      [
        for key, upstream in app.upstreams : {
          name        = key
          value       = "http://${azurerm_container_app.internal[upstream].ingress[0].fqdn}"
          secret_name = null
        }
      ],
    )
  }
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.name_prefix}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  tags = local.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "${local.name_prefix}-cae"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # VNet injection: without it the apps cannot reach the private database or the vault's
  # private endpoint, and the environment gets a shared public IP instead.
  infrastructure_subnet_id = var.infrastructure_subnet_id

  tags = local.tags
}

resource "azurerm_user_assigned_identity" "this" {
  for_each = var.apps

  name                = "${local.name_prefix}-${each.key}-id"
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  for_each = var.apps

  scope                = var.registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this[each.key].principal_id
}

resource "azurerm_role_assignment" "key_vault_secrets" {
  for_each = var.apps

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this[each.key].principal_id
}

resource "azurerm_container_app" "internal" {
  for_each = local.internal_apps

  name                         = "${local.name_prefix}-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this[each.key].id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.this[each.key].id
  }

  dynamic "secret" {
    for_each = each.value.secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.this[each.key].id
    }
  }

  template {
    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas

    container {
      name   = each.key
      image  = each.value.image
      cpu    = each.value.cpu
      memory = each.value.memory

      dynamic "env" {
        for_each = local.internal_env[each.key]

        content {
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret_name
        }
      }

      # Probes hit the plaintext ops surface. The data port is 8443 on the mTLS legs;
      # here everything listens on 8000 because ingress already terminated TLS.
      liveness_probe {
        transport               = "HTTP"
        port                    = var.probe_port
        path                    = "/healthz"
        initial_delay           = 10
        interval_seconds        = 15
        failure_count_threshold = 3
        timeout                 = 5
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = var.probe_port
        path                    = "/readyz"
        initial_delay           = 5
        interval_seconds        = 10
        failure_count_threshold = 3
        success_count_threshold = 1
        timeout                 = 5
      }
    }
  }

  # Internal ingress: no public IP, reachable only from inside the environment.
  ingress {
    external_enabled           = false
    target_port                = each.value.target_port
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = local.tags
}

resource "azurerm_container_app" "public" {
  for_each = local.public_apps

  name                         = "${local.name_prefix}-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this[each.key].id]
  }

  registry {
    server   = var.registry_login_server
    identity = azurerm_user_assigned_identity.this[each.key].id
  }

  dynamic "secret" {
    for_each = each.value.secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = azurerm_user_assigned_identity.this[each.key].id
    }
  }

  template {
    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas

    container {
      name   = each.key
      image  = each.value.image
      cpu    = each.value.cpu
      memory = each.value.memory

      dynamic "env" {
        for_each = local.public_env[each.key]

        content {
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret_name
        }
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = var.probe_port
        path                    = "/healthz"
        initial_delay           = 10
        interval_seconds        = 15
        failure_count_threshold = 3
        timeout                 = 5
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = var.probe_port
        path                    = "/readyz"
        initial_delay           = 5
        interval_seconds        = 10
        failure_count_threshold = 3
        success_count_threshold = 1
        timeout                 = 5
      }
    }
  }

  # The one public workload. TLS is terminated by the platform; `allow_insecure_connections
  # = false` keeps the HTTP listener from serving traffic, so the URL is HTTPS-only.
  ingress {
    external_enabled           = true
    target_port                = each.value.target_port
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = local.tags
}
