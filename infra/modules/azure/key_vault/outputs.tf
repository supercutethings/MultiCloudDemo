output "id" {
  value = azurerm_key_vault.this.id
}

output "name" {
  value = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "Pass as AZURE_KEYVAULT_URI to scripts/k8s-render.sh on the Kubernetes leg."
  value       = azurerm_key_vault.this.vault_uri
}

output "private_dns_zone_id" {
  value = azurerm_private_dns_zone.vault.id
}
