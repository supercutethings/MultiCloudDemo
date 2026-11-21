data "aws_region" "current" {}

locals {
  tags = {
    Project     = var.name_prefix
    Service     = var.name
    ManagedBy   = "terraform"
  }

  container_health_check = {
    # No curl in the slim image, so probe with the Python we already ship.
    command = [
      "CMD-SHELL",
      "python -c \"import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${coalesce(var.health_check_port, var.container_port)}/healthz', timeout=2).status == 200 else 1)\"",
    ]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 20
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}/${var.name}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

# Per-service identity: the workload can only do what this role allows.
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-${var.name}-task"

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

resource "aws_iam_role_policy" "task_inline" {
  count = var.task_role_policy_json == null ? 0 : 1

  name   = "${var.name}-inline"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = var.name
    image     = var.image
    essential = true

    # The data port plus the plaintext ops port (healthz/readyz only) when the former is
    # mTLS-only. Both are container-local; the security groups decide who may reach them.
    portMappings = concat(
      [{ containerPort = var.container_port, protocol = "tcp" }],
      [for port in var.additional_ports : { containerPort = port, protocol = "tcp" }],
    )

    # Configuration is plain environment; credentials are resolved by the
    # execution role at start-up and never appear in the task definition.
    environment = [for key, value in var.environment_variables : { name = key, value = value }]
    secrets     = [for key, value in var.secret_environment_variables : { name = key, valueFrom = value }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = var.name
      }
    }

    healthCheck = local.container_health_check
  }])
}

resource "aws_service_discovery_service" "this" {
  count = var.service_discovery_namespace_id == null ? 0 : 1

  name = var.name

  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.tags
}

resource "aws_lb_target_group" "this" {
  count = var.create_target_group ? 1 : 0

  name        = "${var.name_prefix}-${var.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Fast deregistration keeps rolling deploys short without dropping requests.
  deregistration_delay = 30

  health_check {
    path                = var.target_group_health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

resource "aws_lb_listener_rule" "this" {
  count = var.create_target_group && var.alb_listener_arn != null ? 1 : 0

  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

resource "aws_ecs_service" "this" {
  name             = "${var.name_prefix}-${var.name}"
  cluster          = var.cluster_arn
  task_definition  = aws_ecs_task_definition.this.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  health_check_grace_period_seconds = var.create_target_group ? 60 : null
  wait_for_steady_state             = true

  # If the new task definition cannot become healthy, roll back automatically
  # instead of leaving the service in a half-deployed state.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.create_target_group ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = var.service_discovery_namespace_id == null ? [] : [1]
    content {
      registry_arn = aws_service_discovery_service.this[0].arn
    }
  }

  tags = local.tags

  lifecycle {
    # Owned by autoscaling / rolling deployments, not by Terraform.
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "this" {
  count = var.enable_autoscaling ? 1 : 0

  max_capacity       = var.max_replicas
  min_capacity       = var.min_replicas
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${var.name_prefix}-${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 60
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
