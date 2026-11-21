# Azure Container Registry.
#
# The admin account stays disabled: Container Apps pulls with its own managed identity
# through an AcrPull assignment, which is the Azure equivalent of the ECS task role. An
# admin username/password would be a long-lived credential in a Secret for no benefit.
#
# ACR has no immutable-tag switch (unlike ECR), so the discipline lives in the pipeline:
# images are pushed by commit SHA, and `latest` is never referenced by the manifests.

locals {
  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )

  # Registry names are alphanumeric only, globally unique, 5-50 characters.
  registry_name = substr(replace("${var.project}${var.environment}acr${var.name_suffix}", "-", ""), 0, 50)
}

resource "azurerm_container_registry" "this" {
  name                = local.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  admin_enabled       = false

  tags = local.tags
}
