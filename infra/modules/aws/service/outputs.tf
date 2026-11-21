output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "task_role_arn" {
  description = "Workload identity for this service (reference in docs/cloud-matrix.md)."
  value       = aws_iam_role.task.arn
}

output "target_group_arn" {
  value = var.create_target_group ? aws_lb_target_group.this[0].arn : null
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}

output "internal_url" {
  description = "How other services reach this one inside the VPC."
  value       = var.service_discovery_namespace_id == null ? null : "http://${var.name}.${var.service_discovery_namespace_name}:${var.container_port}"
}
