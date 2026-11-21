# Key Vault: the Azure secret store for the serverless leg.
#
# RBAC (not access policies) because it is the model Azure is converging on, and because
# a role assignment is reviewable in a diff. The private endpoint keeps the data path
# inside the VNet; the public endpoint stays reachable only from the CIDRs you allow,
# which is what lets a laptop or CI seed secrets on a fresh apply.
#
# Unlike Secrets Manager, Key Vault has no JSON property extraction: every value is its
# own secret. That is why the container apps reference three secret URIs instead of one
# JSON blob, and why the Kubernetes overlay does the same thing on this cloud.

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

  # 3-24 characters, alphanumeric and hyphens, globally unique.
  vault_name = substr(replace("${var.project}-${var.environment}-kv-${var.name_suffix}", "_", "-"), 0, 24)
}

resource "azurerm_key_vault" "this" {
  name                = local.vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true

  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = 7

  public_network_access_enabled = var.public_network_access_enabled

  # Deny by default once you have told it where you work from; Allow otherwise, so a
  # fresh clone can seed secrets without a private network path.
  network_acls {
    bypass         = "AzureServices"
    default_action = length(var.allowed_ip_ranges) > 0 ? "Deny" : "Allow"
    ip_rules       = var.allowed_ip_ranges
  }

  tags = local.tags
}

# --- Private path ----------------------------------------------------------------------

resource "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault" {
  name                  = "${local.name_prefix}-kv-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vault.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false

  tags = local.tags
}

resource "azurerm_private_endpoint" "vault" {
  name                = "${local.name_prefix}-kv-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.endpoint_subnet_id

  private_service_connection {
    name                           = "keyvault"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "keyvault"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault.id]
  }

  tags = local.tags
}

# --- Who may do what -------------------------------------------------------------------

# The identity running Terraform has to be able to write the values it just generated.
resource "azurerm_role_assignment" "deployer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.deployer_object_id
}
