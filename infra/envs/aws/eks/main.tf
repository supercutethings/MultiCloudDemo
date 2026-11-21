locals {
  name_prefix  = "${var.project}-${var.environment}"
  cluster_name = "${local.name_prefix}-k8s"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "multicloud-iac-showcase"
    Runtime     = "kubernetes"
  }

  common_env = {
    ENVIRONMENT  = var.environment
    LOG_LEVEL    = "INFO"
    JWT_ISSUER   = "showcase-auth"
    JWT_AUDIENCE = "showcase-api"
  }
}

# --- Network: three AZs, one NAT each ---------------------------------------------------
# The ECS environment runs a single NAT to save $66/month, because a demo does not need AZ
# redundancy. This one does: an AZ failure must not strand egress for the surviving two.

module "network" {
  source = "../../../modules/aws/network"

  project            = var.project
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  az_count           = 3
  enable_nat_gateway = true
  nat_gateway_per_az = true
  cluster_name       = local.cluster_name
}

module "ecr" {
  source = "../../../modules/aws/ecr"

  project     = var.project
  environment = var.environment
}

# --- Secrets ---------------------------------------------------------------------------

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${local.name_prefix}/jwt-keys"
  description             = "RS256 key pair used to sign and verify platform JWTs."
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id = aws_secretsmanager_secret.jwt.id

  secret_string = jsonencode({
    private_key = tls_private_key.jwt.private_key_pem
    public_key  = tls_private_key.jwt.public_key_pem
  })
}

# mTLS certificates are NOT created here: cert-manager issues and rotates them inside the
# cluster (k8s/components/internal-pki), so the cluster environment needs no PKI state and
# no CA key of its own. The ECS environment keeps infra/modules/pki because it has no
# cert-manager. See docs/kubernetes.md and ADR 0006.

# --- Database: Multi-AZ, private, encrypted --------------------------------------------

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
  secret_id     = aws_secretsmanager_secret.database_url.id
  secret_string = jsonencode({ url = module.rds.database_url })
}

# --- Cluster ---------------------------------------------------------------------------

module "eks" {
  source = "../../../modules/aws/eks"

  project      = var.project
  environment  = var.environment
  cluster_name = local.cluster_name

  kubernetes_version  = var.kubernetes_version
  private_subnet_ids  = module.network.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_desired_size   = var.node_desired_size
  node_max_size       = var.node_max_size
  enable_spot_pool    = var.enable_spot_pool

  endpoint_public_access = var.endpoint_public_access
  public_access_cidrs    = var.public_access_cidrs

  # Least privilege for External Secrets: three secrets, nothing else in the account.
  secret_arns = [
    aws_secretsmanager_secret.jwt.arn,
    aws_secretsmanager_secret.database_url.arn,
  ]

  tags = { Owner = var.owner }
}

# The EKS-managed cluster security group is attached to every node ENI, so it is the
# correct source for database traffic. The gateway/auth/catalog pods reach RDS:5432 and
# nothing else in the VPC can.
resource "aws_security_group_rule" "db_from_nodes" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS node ENIs"
  security_group_id        = module.network.db_security_group_id
  source_security_group_id = module.eks.cluster_security_group_id
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
}

# Kubernetes needs egress to pull images (ECR) and to reach the control plane; the private
# route tables already provide it through the per-AZ NAT gateways.
