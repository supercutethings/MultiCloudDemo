resource "google_artifact_registry_repository" "this" {
  project       = var.project
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = var.description

  labels = var.labels

  # Artifact Registry has no "immutable tags" switch, so a cleanup policy does the work:
  # keep the ten most recent versions. CI tags by commit SHA, so nothing here depends on a
  # mutable `latest`, and the repository cannot grow without bound the way ECR would.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"

    most_recent_versions {
      keep_count = 10
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = toset(var.reader_members)

  project    = var.project
  location   = var.region
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
