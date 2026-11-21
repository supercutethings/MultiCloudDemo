output "dns_name" {
  description = "Public DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "url" {
  description = "Base URL to smoke-test against."
  value       = var.certificate_arn == null ? "http://${aws_lb.this.dns_name}" : "https://${aws_lb.this.dns_name}"
}

output "zone_id" {
  description = "Hosted zone id, for the Route53 alias record when a custom domain is added."
  value       = aws_lb.this.zone_id
}

output "listener_arn" {
  value = aws_lb_listener.http.arn
}
