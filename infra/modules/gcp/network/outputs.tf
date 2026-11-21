output "network_id" {
  value = google_compute_network.this.id
}

output "network_name" {
  value = google_compute_network.this.name
}

output "connector_id" {
  description = "Pass as `connector` on a Cloud Run v2 service's vpc_access block."
  value       = google_vpc_access_connector.this.id
}

output "connector_cidr" {
  value = var.connector_cidr
}
