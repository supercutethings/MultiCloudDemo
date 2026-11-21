output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = module.eks.configure_kubectl
}

output "region" {
  value = var.region
}

output "image_repository_prefix" {
  description = "Pass as IMAGE_REPO to scripts/k8s-render.sh; service images append /<name>:<tag>."
  value       = trimsuffix(module.ecr.repository_urls["gateway"], "/gateway")
}

output "repository_urls" {
  value = module.ecr.repository_urls
}

output "secrets_prefix" {
  description = "AWS Secrets Manager prefix the EKS overlay reads (SECRETS_PREFIX)."
  value       = "${var.project}/${var.environment}"
}

output "vpc_cidr" {
  description = "CIDR for the PostgreSQL egress NetworkPolicy (VPC_CIDR)."
  value       = var.vpc_cidr
}

output "irsa_role_arns" {
  description = "Feed these to scripts/cluster-addons.sh (ESO/ALB/CA role ARNs)."
  value       = module.eks.irsa_role_arns
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "database_endpoint" {
  value     = module.rds.database_url
  sensitive = true
}
