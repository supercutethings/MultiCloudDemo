locals {
  name_prefix    = "${var.project}-${var.environment}"
  service_domain = "${var.project}-${var.environment}.local"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "multicloud-iac-showcase"
  }

  # Shared, non-secret configuration for every service.
  common_env = {
    ENVIRONMENT  = var.environment
    LOG_LEVEL    = "INFO"
    JWT_ISSUER   = "showcase-auth"
    JWT_AUDIENCE = "showcase-api"
  }
}

module "network" {
  source = "../../../modules/aws/network"

  project            = var.project
  environment        = var.environment
  az_count           = var.az_count
  enable_nat_gateway = var.enable_nat_gateway
  container_port     = var.container_port
}

module "ecr" {
  source = "../../../modules/aws/ecr"

  project     = var.project
  environment = var.environment
}

# --- Secrets -------------------------------------------------------------------------
# Generated here so a fresh clone works with a single `terraform apply`. The private key
# lives in Terraform state (encrypted S3, access-controlled) and in Secrets Manager.
# Rotation: `terraform apply -replace=tls_private_key.jwt` then redeploy the services.

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${local.name_prefix}/jwt-keys"
  description             = "RS256 key pair used to sign and verify platform JWTs."
  recovery_window_in_days = 0 # immediate delete, so `make destroy` really frees the name

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id = aws_secretsmanager_secret.jwt.id

  secret_string = jsonencode({
    private_key = tls_private_key.jwt.private_key_pem
    public_key  = tls_private_key.jwt.public_key_pem
  })
}

# --- Mutual TLS PKI -------------------------------------------------------------------
# Two trust domains (server CA + one client CA per caller identity), stored as a single
# JSON secret: the ECS execution role maps each property to a TLS_*_PEM variable. Each
# service gets only the client CAs the allow rule permits, so auth cannot be called by a
# workload that catalog would refuse, and vice versa.
module "pki" {
  source = "../../../modules/pki"

  common_name = "${local.name_prefix}-ca"

  service_dns_names = {
    auth    = ["auth", "auth.${local.service_domain}", "localhost"]
    catalog = ["catalog", "catalog.${local.service_domain}", "localhost"]
  }
}

resource "aws_secretsmanager_secret" "pki" {
  name                    = "${local.name_prefix}/pki"
  description             = "mTLS CA and leaf certificates for internal service-to-service calls."
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "pki" {
  secret_id     = aws_secretsmanager_secret.pki.id
  secret_string = jsonencode(module.pki.material)
}

module "rds" {
  source = "../../../modules/aws/rds"

  project            = var.project
  environment        = var.environment
  private_subnet_ids = module.network.private_subnet_ids
  security_group_id  = module.network.db_security_group_id
  instance_class     = var.db_instance_class
  multi_az           = var.db_multi_az
}

resource "aws_secretsmanager_secret" "database_url" {
  name                    = "${local.name_prefix}/database-url"
  description             = "SQLAlchemy connection URL for the services."
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id = aws_secretsmanager_secret.database_url.id
  # sslmode=require: the rds.force_ssl parameter group rejects plaintext anyway, but the
  # URL makes the intent explicit and tests keep working against SQLite.
  secret_string = jsonencode({ url = "${module.rds.database_url}?sslmode=require" })
}

# --- Cluster and execution role -------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = local.tags
}

resource "aws_iam_role" "ecs_execution" {
  name        = "${local.name_prefix}-ecs-execution"
  description = "Pulls images from ECR and resolves secrets at task start-up."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Scoped to the two secrets this platform owns -- not "*".
data "aws_iam_policy_document" "ecs_execution_secrets" {
  statement {
    sid     = "ReadPlatformSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.jwt.arn,
      "${aws_secretsmanager_secret.jwt.arn}*",
      aws_secretsmanager_secret.database_url.arn,
      "${aws_secretsmanager_secret.database_url.arn}*",
      aws_secretsmanager_secret.pki.arn,
      "${aws_secretsmanager_secret.pki.arn}*",
    ]
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name   = "read-platform-secrets"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_secrets.json
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = local.service_domain
  description = "Service-to-service discovery for ${local.name_prefix}"
  vpc         = module.network.vpc_id

  tags = local.tags
}

# --- Services -------------------------------------------------------------------------
# Only the gateway is reachable from the internet; auth and catalog live in private
# subnets and accept traffic exclusively from the gateway security group.

module "auth" {
  source = "../../../modules/aws/service"

  name         = "auth"
  name_prefix  = local.name_prefix
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  image  = "${module.ecr.repository_urls["auth"]}:${var.image_tag}"
  cpu    = var.service_cpu
  memory = var.service_memory

  desired_count      = var.desired_count
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.network.internal_security_group_id]
  execution_role_arn = aws_iam_role.ecs_execution.arn

  # Data port is mTLS-only; 8000 is the plaintext ops port for the task health check.
  container_port    = 8443
  additional_ports  = [8000]
  health_check_port = 8000

  environment_variables = merge(local.common_env, {
    PORT     = "8443"
    OPS_PORT = "8000"
  })

  secret_environment_variables = {
    DATABASE_URL      = "${aws_secretsmanager_secret.database_url.arn}:url::"
    JWT_PRIVATE_KEY   = "${aws_secretsmanager_secret.jwt.arn}:private_key::"
    JWT_PUBLIC_KEY    = "${aws_secretsmanager_secret.jwt.arn}:public_key::"
    TLS_CERT_PEM      = "${aws_secretsmanager_secret.pki.arn}:auth_cert::"
    TLS_KEY_PEM       = "${aws_secretsmanager_secret.pki.arn}:auth_key::"
    TLS_CLIENT_CA_PEM = "${aws_secretsmanager_secret.pki.arn}:auth_client_ca::"
  }

  service_discovery_namespace_id   = aws_service_discovery_private_dns_namespace.this.id
  service_discovery_namespace_name = aws_service_discovery_private_dns_namespace.this.name
}

module "catalog" {
  source = "../../../modules/aws/service"

  name         = "catalog"
  name_prefix  = local.name_prefix
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  image  = "${module.ecr.repository_urls["catalog"]}:${var.image_tag}"
  cpu    = var.service_cpu
  memory = var.service_memory

  desired_count      = var.desired_count
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.network.internal_security_group_id]
  execution_role_arn = aws_iam_role.ecs_execution.arn

  container_port    = 8443
  additional_ports  = [8000]
  health_check_port = 8000

  environment_variables = merge(local.common_env, {
    PORT     = "8443"
    OPS_PORT = "8000"
  })

  secret_environment_variables = {
    DATABASE_URL      = "${aws_secretsmanager_secret.database_url.arn}:url::"
    JWT_PUBLIC_KEY    = "${aws_secretsmanager_secret.jwt.arn}:public_key::"
    TLS_CERT_PEM      = "${aws_secretsmanager_secret.pki.arn}:catalog_cert::"
    TLS_KEY_PEM       = "${aws_secretsmanager_secret.pki.arn}:catalog_key::"
    TLS_CLIENT_CA_PEM = "${aws_secretsmanager_secret.pki.arn}:catalog_client_ca::"
  }

  service_discovery_namespace_id   = aws_service_discovery_private_dns_namespace.this.id
  service_discovery_namespace_name = aws_service_discovery_private_dns_namespace.this.name
}

module "gateway" {
  source = "../../../modules/aws/service"

  name         = "gateway"
  name_prefix  = local.name_prefix
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  image  = "${module.ecr.repository_urls["gateway"]}:${var.image_tag}"
  cpu    = var.service_cpu
  memory = var.service_memory

  desired_count      = var.desired_count
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.network.app_security_group_id]
  execution_role_arn = aws_iam_role.ecs_execution.arn
  container_port     = var.container_port

  environment_variables = merge(local.common_env, {
    # Internal calls are mutual TLS on 8443: the gateway verifies the service certificate
    # against the platform CA and presents its own client certificate.
    AUTH_SERVICE_URL    = "https://auth.${local.service_domain}:8443"
    CATALOG_SERVICE_URL = "https://catalog.${local.service_domain}:8443"
    GIT_SHA             = var.image_tag
  })

  secret_environment_variables = {
    JWT_PUBLIC_KEY = "${aws_secretsmanager_secret.jwt.arn}:public_key::"
    # The gateway verifies services with the server CA; it never trusts its own issuer.
    TLS_CA_PEM          = "${aws_secretsmanager_secret.pki.arn}:server_ca::"
    TLS_CLIENT_CERT_PEM = "${aws_secretsmanager_secret.pki.arn}:gateway_cert::"
    TLS_CLIENT_KEY_PEM  = "${aws_secretsmanager_secret.pki.arn}:gateway_key::"
  }

  service_discovery_namespace_id   = aws_service_discovery_private_dns_namespace.this.id
  service_discovery_namespace_name = aws_service_discovery_private_dns_namespace.this.name

  # The one public workload: target group + autoscaling.
  create_target_group = true
  vpc_id              = module.network.vpc_id
  enable_autoscaling  = var.enable_gateway_autoscaling
  min_replicas        = var.desired_count
  max_replicas        = var.gateway_max_replicas

  depends_on = [module.auth, module.catalog]
}

module "alb" {
  source = "../../../modules/aws/alb"

  name_prefix        = local.name_prefix
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  security_group_ids = [module.network.alb_security_group_id]
  target_group_arn   = module.gateway.target_group_arn
  certificate_arn    = var.certificate_arn
}
