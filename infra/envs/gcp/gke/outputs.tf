output "cluster_name" {
  value = module.gke.cluster_name
}

output "configure_kubectl" {
  value = module.gke.configure_kubectl
}

output "image_repository_prefix" {
  description = "Pass as IMAGE_REPO to scripts/k8s-render.sh."
  value       = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.this.repository_id}"
}

output "vpc_cidr" {
  description = "Pass as VPC_CIDR for the PostgreSQL egress policy."
  value       = var.node_subnet_cidr
}

output "eso_service_account_email" {
  description = "Pass as GCP_SA_EMAIL to scripts/cluster-addons.sh."
  value       = google_service_account.eso.email
}

output "workload_pool" {
  value = module.gke.workload_pool
}

output "database_connection_name" {
  value = google_sql_database_instance.this.connection_name
}

output "static_ip_hint" {
  description = "Reserve the global address before deploying the Ingress (STATIC_IP)."
  value       = "gcloud compute addresses create showcase-ip --global --project ${var.project}"
}
