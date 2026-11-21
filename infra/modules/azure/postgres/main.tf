# PostgreSQL Flexible Server, reachable only from inside the VNet.
#
# `public_network_access_enabled = false` plus a delegated subnet and a private DNS zone
# is the whole point: there is no endpoint on the internet to attack, and the connection
# string resolves only inside the VNet. `require_secure_transport` then removes the
# remaining option of talking plaintext over that private network.

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.name_prefix}.postgres.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${local.name_prefix}-pg-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${local.name_prefix}-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  version = var.postgres_version

  delegated_subnet_id = var.delegated_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id

  administrator_login    = var.admin_login
  administrator_password = var.admin_password

  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  # A zone is only meaningful without HA; with ZoneRedundant the standby gets zone 2.
  zone = var.ha ? null : "1"

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false

  public_network_access_enabled = false

  dynamic "high_availability" {
    for_each = var.ha ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }

  tags = local.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# A client cannot negotiate plaintext, whatever the connection string says.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

resource "azurerm_postgresql_flexible_server_configuration" "ssl_min_protocol" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "TLSv1.2"
}
