output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "oidc_issuer_url" {
  description = "Issuer for federated workload identity credentials."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_object_id" {
  description = "Kubelet identity; needs AcrPull on the registry."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "fqdn" {
  value = azurerm_kubernetes_cluster.this.fqdn
}

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_cidr" {
  value = var.vnet_cidr
}

output "node_subnet_id" {
  value = azurerm_subnet.nodes.id
}

output "data_subnet_id" {
  value = azurerm_subnet.data.id
}

output "endpoint_subnet_id" {
  value = azurerm_subnet.endpoints.id
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "key_vault_secrets_provider_client_id" {
  description = "Client id the Key Vault CSI driver uses; annotate its service account with it."
  value       = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].client_id
}

output "configure_kubectl" {
  value = "az aks get-credentials --resource-group ${var.resource_group_name} --name ${azurerm_kubernetes_cluster.this.name}"
}
