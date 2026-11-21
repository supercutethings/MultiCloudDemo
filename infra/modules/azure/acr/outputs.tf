output "id" {
  value = azurerm_container_registry.this.id
}

output "login_server" {
  description = "Registry host, e.g. showcase-dev-acr-ab12.azurecr.io. Prefix for every image reference."
  value       = azurerm_container_registry.this.login_server
}

output "name" {
  value = azurerm_container_registry.this.name
}
