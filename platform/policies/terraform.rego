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
