output "prefix" {
  description = "Image prefix, e.g. `europe-west1-docker.pkg.dev/project/repo`."
  value       = "${var.region}-docker.pkg.dev/${var.project}/${var.repository_id}"
}

output "repository_id" {
  value = google_artifact_registry_repository.this.repository_id
}

output "name" {
  value = google_artifact_registry_repository.this.name
}
