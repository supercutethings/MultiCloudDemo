data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # One NAT for the whole VPC (cheap, dev) or one per AZ (HA, prod). The ECS environment
  # keeps a single gateway; the EKS environment sets nat_gateway_per_az = true so losing an
  # AZ does not cut egress for the surviving zones.
  nat_count = var.enable_nat_gateway ? (var.nat_gateway_per_az ? var.az_count : 1) : 0

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Required by the AWS Load Balancer Controller to discover subnets. Only added when a
  # cluster name is supplied, so the ECS environment's subnets stay untouched.
  cluster_tags = var.cluster_name == null ? {} : {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  public_role  = var.cluster_name == null ? {} : { "kubernetes.io/role/elb" = "1" }
  private_role = var.cluster_name == null ? {} : { "kubernetes.io/role/internal-elb" = "1" }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}

# --- Public subnets: only the load balancer and the NAT gateway live here --------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, local.cluster_tags, local.public_role, {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets: ECS tasks and RDS -----------------------------------------------

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, local.cluster_tags, local.private_role, {
    Name = "${local.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-private-${count.index + 1}" })
}

# A single NAT gateway is the cheap, honest dev choice: no AZ redundancy, ~$33/month.
# For prod, run one per AZ (nat_gateway_per_az = true): ~$99/month, and an AZ failure no
# longer strands egress for the surviving zones.
resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(local.tags, { Name = "${local.name_prefix}-nat-${count.index + 1}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${local.name_prefix}-nat-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  count = local.nat_count > 0 ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # One NAT: every AZ shares it. One per AZ: each route table uses its own.
  nat_gateway_id = aws_nat_gateway.this[var.nat_gateway_per_az ? count.index : 0].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- Security groups, chained so each tier only accepts traffic from the tier above ----

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Public ingress to the load balancer."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP (redirected to HTTPS when a certificate is configured)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the gateway tasks"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-alb" })
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app"
  description = "Gateway tasks: ingress only from the load balancer."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From the ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound for image pulls, upstream services and the database"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-app" })
}

resource "aws_security_group" "internal" {
  name        = "${local.name_prefix}-internal"
  description = "Auth and catalog tasks: ingress only from the gateway."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "From the gateway, on the mTLS data port only"
    from_port   = var.internal_port
    to_port     = var.internal_port
    protocol    = "tcp"

    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "Outbound for image pulls and the database"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-internal" })
}

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db"
  description = "PostgreSQL: ingress only from the application tiers."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From the gateway, auth and catalog tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id, aws_security_group.internal.id]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-db" })
}
