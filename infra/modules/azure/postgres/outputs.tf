output "server_id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "fqdn" {
  description = "Private FQDN; resolves only inside the VNet."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "database_url" {
  description = "SQLAlchemy URL. sslmode=require matches the server-side require_secure_transport."
  value = format(
    "postgresql+psycopg://%s:%s@%s:5432/%s?sslmode=require",
    var.admin_login,
    var.admin_password,
    azurerm_postgresql_flexible_server.this.fqdn,
    azurerm_postgresql_flexible_server_database.app.name,
  )
  sensitive = true
}
