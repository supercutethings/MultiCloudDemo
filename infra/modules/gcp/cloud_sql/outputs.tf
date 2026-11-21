output "private_ip" {
  description = "Private address, reachable from the connector and nothing else."
  value       = google_sql_database_instance.this.private_ip_address
}

output "connection_name" {
  description = "project:region:instance, for `gcloud sql connect` through the proxy."
  value       = google_sql_database_instance.this.connection_name
}

output "instance_name" {
  value = google_sql_database_instance.this.name
}

output "database_url" {
  description = "SQLAlchemy URL pointing at the private address."
  value       = "postgresql+psycopg://${var.user_name}:${var.password}@${google_sql_database_instance.this.private_ip_address}:5432/${var.database_name}?sslmode=require"
  sensitive   = true
}
