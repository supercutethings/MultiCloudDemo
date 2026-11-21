# Secret Manager, one secret per value.
#
# Values arrive as a map and are marked sensitive, so `for_each` iterates over the *keys*
# (never secret) and the data is read inside each resource. Access is granted per secret to
# an explicit list of service accounts -- the GCP equivalent of the per-app managed identity
# in the Azure leg and the per-service task role in the AWS one. No key file exists anywhere.

resource "google_secret_manager_secret" "this" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  project   = var.project
  secret_id = each.key

  labels = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = var.secrets[each.key]
}

locals {
  accessor_pairs = merge([
    for name, members in var.accessors : {
      for member in members : "${name}|${member}" => { secret = name, member = member }
    }
  ]...)
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = local.accessor_pairs

  project   = var.project
  secret_id = google_secret_manager_secret.this[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}
