output "url" {
  description = "Public gateway URL. Pass to `make smoke LOCAL_URL=...`."
  value       = module.apps.app_urls["gateway"]
}

output "internal_urls" {
  description = "In-environment URLs for auth and catalog (not reachable from the internet)."
  value = {
    auth    = module.apps.app_urls["auth"]
    catalog = module.apps.app_urls["catalog"]
  }
}

output "environment_default_domain" {
  value = module.apps.environment_default_domain
}

output "image_repository_prefix" {
  description = "Prefix for image references, e.g. `docker tag auth <prefix>/auth:<sha>`."
  value       = module.acr.login_server
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "azure_keyvault_uri" {
  description = "Pass as AZURE_KEYVAULT_URI when rendering the AKS overlay."
  value       = module.key_vault.vault_uri
}

output "database_fqdn" {
  value = module.postgres.fqdn
}

output "vnet_cidr" {
  value = module.network.vnet_cidr
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "log_analytics_workspace_id" {
  value = module.apps.log_analytics_workspace_id
}
