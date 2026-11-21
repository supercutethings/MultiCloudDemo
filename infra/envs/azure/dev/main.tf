locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "multicloud-iac-showcase"
    Runtime     = "container-apps"
  }

  # Shared, non-secret configuration for every service -- the same map the ECS
  # environment builds, so the application code cannot tell the clouds apart.
  common_env = {
    ENVIRONMENT  = var.environment
    LOG_LEVEL    = "INFO"
    JWT_ISSUER   = "showcase-auth"
    JWT_AUDIENCE = "showcase-api"
  }
}

data "azurerm_client_config" "current" {}

# Globally unique names (registry, vault, server) get a suffix so two applies in different
# subscriptions -- or two people on the same one -- do not collide.
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name_prefix}-rg"
  location = var.location

  tags = local.tags
}

module "network" {
  source = "../../../modules/azure/network"

  project             = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name

  vnet_cidr            = var.vnet_cidr
  apps_subnet_cidr     = var.apps_subnet_cidr
  data_subnet_cidr     = var.data_subnet_cidr
  endpoint_subnet_cidr = var.endpoint_subnet_cidr

  tags = local.tags
}

module "acr" {
  source = "../../../modules/azure/acr"

  project             = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  name_suffix         = random_string.suffix.result
  sku                 = var.acr_sku

  tags = local.tags
}

module "key_vault" {
  source = "../../../modules/azure/key_vault"

  project             = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  name_suffix         = random_string.suffix.result

  vnet_id            = module.network.vnet_id
  endpoint_subnet_id = module.network.endpoint_subnet_id
  deployer_object_id = data.azurerm_client_config.current.object_id

  allowed_ip_ranges        = var.key_vault_allowed_ip_ranges
  purge_protection_enabled = var.environment == "prod"

  tags = local.tags
}

module "postgres" {
  source = "../../../modules/azure/postgres"

  project             = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  name_suffix         = random_string.suffix.result

  vnet_id             = module.network.vnet_id
  delegated_subnet_id = module.network.data_subnet_id

  postgres_version = var.postgres_version
  sku_name         = var.db_sku
  storage_mb       = var.db_storage_mb
  ha               = var.db_ha
  admin_login      = var.db_admin_login
  admin_password   = random_password.db.result

  tags = local.tags
}

# --- Secrets ---------------------------------------------------------------------------
# Generated here so a fresh clone works with a single `terraform apply`. Rotation:
# `terraform apply -replace=tls_private_key.jwt` and the apps pick up the new version on
# their next revision. Key Vault has no JSON property extraction, so each value is its own
# secret -- three URIs instead of one blob, same Kubernetes Secret keys on the other legs.

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_key_vault_secret" "jwt_private" {
  name         = "jwt-private-key"
  value        = tls_private_key.jwt.private_key_pem
  key_vault_id = module.key_vault.id
  content_type = "pem"

  depends_on = [module.key_vault]
}

resource "azurerm_key_vault_secret" "jwt_public" {
  name         = "jwt-public-key"
  value        = tls_private_key.jwt.public_key_pem
  key_vault_id = module.key_vault.id
  content_type = "pem"

  depends_on = [module.key_vault]
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "database-url"
  value        = module.postgres.database_url
  key_vault_id = module.key_vault.id
  content_type = "text/plain"

  depends_on = [module.key_vault]
}

# --- Services --------------------------------------------------------------------------

module "apps" {
  source = "../../../modules/azure/container_apps"

  project             = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name

  infrastructure_subnet_id = module.network.apps_subnet_id
  registry_id              = module.acr.id
  registry_login_server    = module.acr.login_server
  key_vault_id             = module.key_vault.id
  log_retention_days       = var.log_retention_days

  apps = {
    auth = {
      image        = "${module.acr.login_server}/auth:${var.image_tag}"
      cpu          = 0.25
      memory       = "0.5Gi"
      min_replicas = var.service_min_replicas
      max_replicas = var.service_max_replicas
      external     = false
      target_port  = 8000

      env = merge(local.common_env, { PORT = "8000" })

      secrets = {
        DATABASE_URL    = azurerm_key_vault_secret.database_url.versionless_id
        JWT_PRIVATE_KEY = azurerm_key_vault_secret.jwt_private.versionless_id
        JWT_PUBLIC_KEY  = azurerm_key_vault_secret.jwt_public.versionless_id
      }

      upstreams = {}
    }

    catalog = {
      image        = "${module.acr.login_server}/catalog:${var.image_tag}"
      cpu          = 0.25
      memory       = "0.5Gi"
      min_replicas = var.service_min_replicas
      max_replicas = var.service_max_replicas
      external     = false
      target_port  = 8000

      env = merge(local.common_env, { PORT = "8000" })

      secrets = {
        DATABASE_URL   = azurerm_key_vault_secret.database_url.versionless_id
        JWT_PUBLIC_KEY = azurerm_key_vault_secret.jwt_public.versionless_id
      }

      upstreams = {}
    }

    gateway = {
      image        = "${module.acr.login_server}/gateway:${var.image_tag}"
      cpu          = 0.25
      memory       = "0.5Gi"
      min_replicas = var.gateway_min_replicas
      max_replicas = var.gateway_max_replicas
      external     = true
      target_port  = 8000

      # Internal URLs are filled in by the module from the real app FQDNs.
      env = merge(local.common_env, {
        PORT    = "8000"
        GIT_SHA = var.image_tag
      })

      secrets = {
        JWT_PUBLIC_KEY = azurerm_key_vault_secret.jwt_public.versionless_id
      }

      upstreams = {
        AUTH_SERVICE_URL    = "auth"
        CATALOG_SERVICE_URL = "catalog"
      }
    }
  }

  tags = local.tags

  depends_on = [
    azurerm_key_vault_secret.database_url,
    azurerm_key_vault_secret.jwt_private,
    azurerm_key_vault_secret.jwt_public,
  ]
}
