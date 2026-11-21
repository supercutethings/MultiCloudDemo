package main

# Evaluated against `terraform show -json tfplan`. Three checks that catch the
# mistakes most likely to turn an IaC demo into an incident.

# 1. No world-open ingress except HTTP/HTTPS.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "aws_security_group"

  rule := resource.change.after.ingress[_]
  rule.cidr_blocks[_] == "0.0.0.0/0"
  rule.from_port != 80
  rule.from_port != 443

  msg := sprintf("%s: ingress from 0.0.0.0/0 on port %v is not allowed", [resource.address, rule.from_port])
}

# 2. Every database instance must be encrypted at rest.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "aws_db_instance"

  not resource.change.after.storage_encrypted

  msg := sprintf("%s: RDS storage must be encrypted", [resource.address])
}

# 3. Every database instance must stay private.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "aws_db_instance"

  resource.change.after.publicly_accessible

  msg := sprintf("%s: RDS must not be publicly accessible", [resource.address])
}

# 4. The Azure database must stay inside its delegated subnet.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "azurerm_postgresql_flexible_server"

  resource.change.after.public_network_access_enabled

  msg := sprintf("%s: Flexible Server must not enable public network access", [resource.address])
}

# 5. Container Apps must not serve plaintext on a public listener.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "azurerm_container_app"

  ingress := resource.change.after.ingress[_]
  ingress.allow_insecure_connections

  msg := sprintf("%s: Container App ingress must not allow insecure connections", [resource.address])
}

# 6. No registry admin account: workloads pull with a managed identity.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "azurerm_container_registry"

  resource.change.after.admin_enabled

  msg := sprintf("%s: ACR admin account must stay disabled; use a managed identity", [resource.address])
}

# 7. The GCP database must keep its private address only.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "google_sql_database_instance"

  ip := resource.change.after.settings[_].ip_configuration[_]
  ip.ipv4_enabled

  msg := sprintf("%s: Cloud SQL must not enable a public IP", [resource.address])
}

# 8. Only the gateway may accept traffic from the internet.
deny[msg] {
  resource := input.resource_changes[_]
  action := resource.change.actions[_]
  action != "delete"
  resource.type == "google_cloud_run_v2_service"

  resource.change.after.ingress == "INGRESS_TRAFFIC_ALL"
  not endswith(resource.change.after.name, "gateway")

  msg := sprintf("%s: only the gateway may accept traffic from the internet", [resource.address])
}
