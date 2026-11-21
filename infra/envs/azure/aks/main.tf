locals {
  name_prefix  = "${var.project}-${var.environment}"
  cluster_name = "${local.name_prefix}-aks"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "multicloud-iac-showcase"
    Runtime     = "kubernetes"
  }
}

data "azurerm_client_config" "current" {}

# Globally unique names (registry, vault, server) get a random suffix so two applies in
# different subscriptions -- or two students on the same one -- do not collide.
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

module "aks" {
  source = "../../../modules/azure/aks"

  project             = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  name_suffix         = random_string.suffix.result

  vnet_cidr           = var.vnet_cidr
  node_subnet_cidr    = var.node_subnet_cidr
  data_subnet_cidr    = var.data_subnet_cidr
  endpoint_subnet_cidr = var.endpoint_subnet_cidr
  appgw_subnet_cidr   = var.appgw_subnet_cidr

  node_vm_size   = var.node_vm_size
  node_min_count = var.node_min_count
  node_max_count = var.node_max_count
  zone_redundant = var.zone_redundant

  private_cluster_enabled         = var.private_cluster_enabled
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges
  enable_defender                 = var.enable_defender
  acr_sku                         = var.acr_sku

  tags = local.tags
}

# --- PostgreSQL Flexible Server: zone-redundant ----------------------------------------

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.name_prefix}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${local.name_prefix}-pg-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = module.aks.vnet_id
  registration_enabled  = false

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${local.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  version = var.postgres_version

  delegated_subnet_id = module.aks.data_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id

  administrator_login    = var.db_admin_login
  administrator_password = random_password.db.result

  sku_name   = var.db_sku
  storage_mb = var.db_storage_mb
  zone       = "1"

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # No public endpoint at all: the server exists only inside the delegated subnet.
  public_network_access_enabled = false

  dynamic "high_availability" {
    for_each = var.db_ha ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }

  tags = local.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "app"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# --- Key Vault --------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  # 3-24 characters, alphanumeric and hyphens, globally unique.
  name                = substr("${var.project}${var.environment}kv${random_string.suffix.result}", 0, 24)
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization     = true
  purge_protection_enabled      = var.environment == "prod"
  soft_delete_retention_days    = 7
  public_network_access_enabled = true

  # Deny by default: only the allowlisted admin IPs and the private endpoint can read it.
  # With no admin ranges configured it falls back to Allow, which is what makes a fresh
  # clone deployable; set the variable for anything real.
  network_acls {
    bypass         = "AzureServices"
    default_action = length(var.key_vault_admin_ip_ranges) > 0 ? "Deny" : "Allow"
    ip_rules       = var.key_vault_admin_ip_ranges
  }

  tags = local.tags
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "${local.name_prefix}-kv-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = module.aks.vnet_id
  registration_enabled  = false

  tags = local.tags
}

resource "azurerm_private_endpoint" "keyvault" {
  name                = "${local.name_prefix}-kv-pe"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = module.aks.endpoint_subnet_id

  private_service_connection {
    name                           = "keyvault"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "keyvault"
    private_dns_zone_ids = [azurerm_private_dns_zone.keyvault.id]
  }

  tags = local.tags
}

# The identity running Terraform needs write access to seed the secrets.
resource "azurerm_role_assignment" "deployer_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Secrets ----------------------------------------------------------------------------

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_key_vault_secret" "jwt_private" {
  name         = "jwt-private-key"
  value        = tls_private_key.jwt.private_key_pem
  key_vault_id = azurerm_key_vault.this.id
  content_type = "pem"

  depends_on = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "jwt_public" {
  name         = "jwt-public-key"
  value        = tls_private_key.jwt.public_key_pem
  key_vault_id = azurerm_key_vault.this.id
  content_type = "pem"

  depends_on = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "database_url" {
  name = "database-url"
  value = format(
    "postgresql+psycopg://%s:%s@%s:5432/app?sslmode=require",
    var.db_admin_login,
    random_password.db.result,
    azurerm_postgresql_flexible_server.this.fqdn,
  )
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"

  depends_on = [azurerm_role_assignment.deployer_secrets]
}

# mTLS certificates are issued and rotated inside the cluster by cert-manager
# (k8s/components/internal-pki), not stored in Key Vault and not managed by Terraform. That
# keeps the CA key out of state on this path and gives automatic renewal. See ADR 0006.

# Server-side TLS enforcement for PostgreSQL: a client cannot downgrade to plaintext.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

# --- Workload identity for External Secrets ---------------------------------------------
# A user-assigned identity federated to the ESO service account. No client secret exists,
# so there is nothing to rotate or leak.

resource "azurerm_user_assigned_identity" "eso" {
  name                = "${local.name_prefix}-eso"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  tags = local.tags
}

resource "azurerm_federated_identity_credential" "eso" {
  name                      = "external-secrets"
  resource_group_name       = azurerm_resource_group.this.name
  parent_id                 = azurerm_user_assigned_identity.eso.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_url
  subject                   = "system:serviceaccount:external-secrets:external-secrets"
}

resource "azurerm_role_assignment" "eso_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}
