output "url" {
  description = "Public entrypoint. Run `make smoke LOCAL_URL=<url>` against it."
  value       = module.alb.url
}

output "ecr_repository_urls" {
  description = "Push targets for the three services."
  value       = module.ecr.repository_urls
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_names" {
  value = {
    auth    = module.auth.service_name
    catalog = module.catalog.service_name
    gateway = module.gateway.service_name
  }
}

output "log_groups" {
  value = {
    auth    = module.auth.log_group_name
    catalog = module.catalog.log_group_name
    gateway = module.gateway.log_group_name
  }
}

output "internal_urls" {
  description = "Private DNS names used for service-to-service traffic (Cloud Map)."
  value = {
    auth    = module.auth.internal_url
    catalog = module.catalog.internal_url
    gateway = module.gateway.internal_url
  }
}

output "database_endpoint" {
  description = "RDS host:port. Reachable only from inside the VPC."
  value       = module.rds.endpoint
}

output "image_tag" {
  description = "Image tag currently deployed. Drift plans use this, not the variable default."
  value       = var.image_tag
}

output "task_role_arns" {
  description = "Per-service workload identities (least privilege, one role each)."
  value = {
    auth    = module.auth.task_role_arn
    catalog = module.catalog.task_role_arn
    gateway = module.gateway.task_role_arn
  }
}
