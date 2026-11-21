output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Subnets for the load balancer and NAT gateway."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets for ECS tasks and RDS."
  value       = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Gateway tasks (public-facing workloads)."
  value       = aws_security_group.app.id
}

output "internal_security_group_id" {
  description = "Internal services (auth, catalog)."
  value       = aws_security_group.internal.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}
