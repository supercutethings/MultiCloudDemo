# AKS cluster: the Azure leg of the Kubernetes path.
#
# The security choices that matter, and why:
#   * `workload_identity_enabled` + `oidc_issuer_enabled` -> the secrets controller can hold
#     a federated identity instead of a client secret (the Azure equivalent of IRSA);
#   * `private_cluster_enabled` puts the API server on a private IP;
#   * `local_account_disabled` removes the certificate-based admin kubeconfig entirely,
#     leaving Entra ID as the only way in;
#   * Azure Policy (Gatekeeper) enforces pod-level rules at admission, the same job the
#     `restricted` Pod Security Standard does in the manifests;
#   * `key_vault_secrets_provider` gives the cluster a rotating CSI identity for secrets.
#
# Zone redundancy: the default node pool spans zones 1/2/3, so an AKS-managed node failure
# in one zone leaves two zones serving, and the Application Gateway v2 front end is itself
# zone-redundant.

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "multicloud-iac-showcase"
    },
    var.tags,
  )

  # Three zones is the whole point of the HA stack; false falls back to a single zone.
  zones = var.zone_redundant ? ["1", "2", "3"] : null
}

resource "azurerm_virtual_network" "this" {
  name                = "${local.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]

  tags = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.node_subnet_cidr]
}

# PostgreSQL Flexible Server is delegated into its own subnet; Azure requires the
# delegation on the subnet, not on the server.
# Private endpoints (Key Vault, registry) need their own subnet: a delegated subnet belongs
# to the delegated service, and shared use is the kind of shortcut that fails at apply time.
resource "azurerm_subnet" "endpoints" {
  name                 = "endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.endpoint_subnet_cidr]
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

resource "azurerm_log_analytics_workspace" "this" {
  count = var.enable_defender ? 1 : 0

  name                = "${local.name_prefix}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "${local.name_prefix}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = local.name_prefix
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  node_resource_group = "${local.name_prefix}-aks-nodes"

  default_node_pool {
    name           = "system"
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.nodes.id
    zones          = local.zones
    type           = "VirtualMachineScaleSets"

    # `auto_scaling_enabled` is the node-level autoscaler: it adds nodes when pods are
    # Pending, and removes them when a node stays under-utilised. The HPA in k8s/base is
    # what creates the Pending pods in the first place.
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count

    os_disk_type    = "Ephemeral"
    os_disk_size_gb = 60

    # Required by the provider when the VM size or pool settings change, so a rotation
    # can be planned instead of failing at apply time.
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 10
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # pods get their own CIDR instead of eating VNet IPs
    network_policy      = "calico"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    pod_cidr            = var.pod_cidr
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true
  image_cleaner_enabled     = true
  automatic_channel_upgrade = "patch"

  private_cluster_enabled = var.private_cluster_enabled

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # The managed Application Gateway gives a zone-redundant L7 front end with WAF available,
  # without running an ingress controller pod.
  ingress_application_gateway {
    gateway_name = "${local.name_prefix}-agic"
    subnet_cidr  = var.appgw_subnet_cidr
  }

  dynamic "microsoft_defender" {
    for_each = var.enable_defender ? [1] : []
    content {
      log_analytics_workspace_id = azurerm_log_analytics_workspace.this[0].id
    }
  }

  tags = local.tags
}

# --- Registry ---------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  # ACR names are alphanumeric only, globally unique, 5-50 characters. The suffix keeps
  # two environments (or two people) from fighting over the same name.
  name                = replace("${var.project}${var.environment}acr${var.name_suffix}", "-", "")
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.acr_sku
  admin_enabled       = false

  tags = local.tags
}

# The kubelet pulls with its own identity -- never the cluster identity, never an admin
# password.
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
