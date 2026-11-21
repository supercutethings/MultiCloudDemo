variable "project" {
  description = "GCP project id (not the display name) that holds the state bucket and the CI identity."
  type        = string
}

variable "region" {
  description = "Region for the state bucket and the default region for the environment roots."
  type        = string
  default     = "europe-west1"
}

variable "github_org" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name (without the owner)."
  type        = string
}

variable "state_bucket_name" {
  description = "Override the generated bucket name. Empty means `<project>-tfstate-<project-number>`."
  type        = string
  default     = ""
}

variable "ci_roles" {
  description = <<-EOT
    Project roles granted to the CI service account. Deliberately broad for a demo, in the
    same spirit as PowerUserAccess in the AWS bootstrap, but listed explicitly so the blast
    radius is visible. `iam.serviceAccountUser` is required: the apply impersonates the
    per-service accounts that Cloud Run runs as.
  EOT
  type        = list(string)
  default = [
    "roles/run.admin",
    "roles/cloudsql.admin",
    "roles/compute.networkAdmin",
    "roles/vpcaccess.admin",
    "roles/secretmanager.admin",
    "roles/artifactregistry.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ]
}
