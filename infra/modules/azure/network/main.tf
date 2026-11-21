# VNet for the Container Apps leg.
#
# Three subnets, because each one is owned by a different thing and Azure refuses to
# share a delegated subnet:
#   * `apps`      -- delegated to Microsoft.App/environments; the environment's
#                    infrastructure lives here, and it is the only place pods get an IP;
#   * `data`      -- delegated to PostgreSQL Flexible Server; a delegated subnet cannot
#                    hold anything else, which is why the database is not "just a VM";
#   * `endpoints` -- private endpoints (Key Vault). Not delegated, but still dedicated:
#                    mixing private endpoints into the app subnet is a common and
#                    confusing failure.
#
# A /23 for the app subnet is deliberate. The environment allocates addresses for every
# replica, so a /24 runs out silently during a scale-out test.

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "multicloud-iac-showcase"
      Runtime     = "container-apps"
    },
    var.tags,
  )
}

resource "azurerm_virtual_network" "this" {
  name                = "${local.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]

  tags = local.tags
}

resource "azurerm_subnet" "apps" {
  name                 = "apps"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.apps_subnet_cidr]

  delegation {
    name = "container-apps"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "data" {
  name                 = "data"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.data_subnet_cidr]

  delegation {
    name = "postgresql"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "endpoints" {
  name                 = "endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.endpoint_subnet_cidr]
}

# The database subnet has no internet path by design. The default Azure rules already
# allow VNet traffic, so this NSG only has to say "not from the internet, and only the
# app subnet may reach 5432" -- an explicit statement beats an implicit one.
resource "azurerm_network_security_group" "data" {
  name                = "${local.name_prefix}-data-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-apps-to-postgres"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = var.apps_subnet_cidr
    destination_address_prefix = "*"
  }

  tags = local.tags
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = azurerm_subnet.data.id
  network_security_group_id = azurerm_network_security_group.data.id
}
