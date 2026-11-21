output "environment_id" {
  value = azurerm_container_app_environment.this.id
}

output "environment_default_domain" {
  value = azurerm_container_app_environment.this.default_domain
}

output "environment_static_ip" {
  description = "Ingress IP of the environment, when it has one."
  value       = azurerm_container_app_environment.this.static_ip_address
}

output "app_urls" {
  description = "Reachable URL per app: https for public, http inside the environment otherwise."
  value = merge(
    { for name, app in azurerm_container_app.internal : name => "http://${app.ingress[0].fqdn}" },
    { for name, app in azurerm_container_app.public : name => "https://${app.ingress[0].fqdn}" },
  )
}

output "identity_ids" {
  description = "User-assigned identity per app (the contract's workload_identity_id)."
  value       = { for name, identity in azurerm_user_assigned_identity.this : name => identity.id }
}

output "log_analytics_workspace_id" {
  description = "Queryable log destination for every app (the contract's log_group_id)."
  value       = azurerm_log_analytics_workspace.this.id
}
