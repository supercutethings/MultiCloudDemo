locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# 32 random alphanumerics: no special characters, so the password can be embedded in a
# connection URL without percent-encoding mistakes.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db"
  subnet_ids = var.private_subnet_ids

  tags = merge(local.tags, { Name = "${local.name_prefix}-db" })
}

# Required, not optional: the connection URLs use sslmode=require, and a parameter group is
# the only way to make PostgreSQL refuse plaintext connections server-side. Belt and
# braces -- TLS on the wire plus a server that will not accept a downgrade.
resource "aws_db_parameter_group" "this" {
  name        = "${local.name_prefix}-pg"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "Force TLS on every connection"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-pg" })
}

resource "aws_db_instance" "this" {
  identifier = "${local.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  allocated_storage      = var.allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true
  publicly_accessible    = false
  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = true
  apply_immediately       = true

  auto_minor_version_upgrade   = true
  performance_insights_enabled = var.performance_insights

  tags = merge(local.tags, { Name = "${local.name_prefix}-postgres" })
}
