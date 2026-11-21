terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Local state on purpose: this stack creates the bucket that would hold it.
}

provider "google" {
  project = var.project
  region  = var.region
}

data "google_project" "current" {
  project_id = var.project
}

locals {
  labels = {
    project     = var.project
    environment = "bootstrap"
    managed_by  = "terraform"
  }

  project_number = data.google_project.current.number

  # Bucket names are globally unique, so the project number is part of the name.
  state_bucket = var.state_bucket_name != "" ? var.state_bucket_name : "${var.project}-tfstate-${local.project_number}"

  service_account_id    = "${var.project}-github-actions"
  service_account_email = "${local.service_account_id}@${var.project}.iam.gserviceaccount.com"

  # The APIs the plan/apply jobs touch. `iamcredentials` is the one people forget: without
  # it the federation handshake succeeds and the impersonation of the service account fails.
  apis = [
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.apis)

  project            = var.project
  service            = each.value
  disable_on_destroy = false
}

# --- State bucket ---------------------------------------------------------------------

resource "google_storage_bucket" "state" {
  name                        = local.state_bucket
  project                     = var.project
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  # Versioning without a lifecycle rule is an unbounded bill and an unbounded surprise.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  labels = local.labels

  depends_on = [google_project_service.this]
}

# --- GitHub Actions OIDC: no service account key, ever --------------------------------

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project
  workload_identity_pool_id = "${var.project}-github"
  display_name              = "GitHub Actions"
  description               = "OIDC pool for ${var.github_org}/${var.github_repo}."

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"
  description                        = "Exchanges a GitHub OIDC token for a federated Google credential."

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.workflow"   = "assertion.workflow"
  }

  # A token issued to any other repository is rejected here, before it reaches a principal.
  # This is the GCP equivalent of the `sub` condition in the AWS trust policy: without it,
  # every GitHub repository in the world shares this pool.
  attribute_condition = "assertion.repository == \"${var.github_org}/${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci" {
  project      = var.project
  account_id   = local.service_account_id
  display_name = "GitHub Actions (terraform plan/apply)"

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "ci" {
  for_each = toset(var.ci_roles)

  project = var.project
  role    = each.value
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Only identities federated from this repository, through this pool, may impersonate the
# service account. `principalSet` is the whole set of subjects carrying that repository
# attribute -- it is not a single principal.
resource "google_service_account_iam_member" "ci_workload_identity" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_org}/${var.github_repo}"
}

# State access is granted on the bucket, not through roles/storage.admin on the project:
# the CI identity can read and write this state and nothing else in the project's storage.
resource "google_storage_bucket_iam_member" "ci_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ci.email}"
}
