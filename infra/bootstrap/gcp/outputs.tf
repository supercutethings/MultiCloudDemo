output "state_bucket" {
  description = "GCS bucket that stores Terraform state. Set as the GCP_TF_STATE_BUCKET repository variable."
  value       = google_storage_bucket.state.name
}

output "backend_hcl" {
  description = "Ready-to-use partial backend configuration for an environment root."
  value       = <<-EOT
    bucket = "${google_storage_bucket.state.name}"
  EOT
}

output "workload_identity_provider" {
  description = "Full provider resource name. Set as the GCP_WORKLOAD_IDENTITY_PROVIDER repository variable."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "service_account_email" {
  description = "Service account the workflow impersonates. Set as the GCP_SERVICE_ACCOUNT repository variable."
  value       = google_service_account.ci.email
}

output "project_id" {
  description = "Project id, echoed so the plan/apply jobs can pass -var project=<id>."
  value       = var.project
}

output "region" {
  description = "Region the backend lives in."
  value       = var.region
}
