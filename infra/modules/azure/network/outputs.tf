output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "vnet_cidr" {
  value = var.vnet_cidr
}

output "apps_subnet_id" {
  description = "Subnet the Container Apps environment is injected into."
  value       = azurerm_subnet.apps.id
}

output "data_subnet_id" {
  description = "Delegated subnet for the flexible server."
  value       = azurerm_subnet.data.id
}

output "endpoint_subnet_id" {
  description = "Subnet for private endpoints."
  value       = azurerm_subnet.endpoints.id
}
