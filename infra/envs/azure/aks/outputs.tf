output "cluster_name" {
  value = module.aks.cluster_name
}

output "configure_kubectl" {
  value = module.aks.configure_kubectl
}

output "image_repository_prefix" {
  description = "Pass as IMAGE_REPO to scripts/k8s-render.sh."
  value       = module.aks.acr_login_server
}

output "acr_login_server" {
  value = module.aks.acr_login_server
}

output "azure_keyvault_uri" {
  description = "Pass as AZURE_KEYVAULT_URI."
  value       = azurerm_key_vault.this.vault_uri
}

output "vnet_cidr" {
  value = module.aks.vnet_cidr
}

output "eso_client_id" {
  description = "Pass as AZURE_CLIENT_ID to scripts/cluster-addons.sh."
  value       = azurerm_user_assigned_identity.eso.client_id
}

output "oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "database_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}
