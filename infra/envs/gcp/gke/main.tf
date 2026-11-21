locals {
  name_prefix  = "${var.project}-${var.environment}"
  cluster_name = "${local.name_prefix}-gke"

  labels = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
    repository  = "multicloud-iac-showcase"
  }

  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "servicenetworking.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project            = var.project
  service            = each.value
  disable_on_destroy = false
}

# --- Network: custom VPC with explicit pod/service ranges -------------------------------

resource "google_compute_network" "this" {
  name                    = "${local.name_prefix}-vpc"
  project                 = var.project
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  depends_on = [google_project_service.this]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${local.name_prefix}-nodes"
  project       = var.project
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.node_subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # Nodes have no external IPs; Private Google Access + Cloud NAT provide egress.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "this" {
  name    = "${local.name_prefix}-router"
  project = var.project
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${local.name_prefix}-nat"
  project                            = var.project
  region                             = var.region
  router                             = google_compute_router.this.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

module "gke" {
  source = "../../../modules/gcp/gke"

  project      = var.project
  environment  = var.environment
  cluster_name = local.cluster_name
  region       = var.region

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.nodes.id

  zones = var.zones

  machine_type       = var.machine_type
  min_nodes_per_zone = var.min_nodes_per_zone
  max_nodes_per_zone = var.max_nodes_per_zone

  enable_private_endpoint     = var.enable_private_endpoint
  master_authorized_networks  = var.master_authorized_networks
  deletion_protection         = var.deletion_protection

  labels = local.labels
}

# --- Cloud SQL: private IP, regional (HA) ----------------------------------------------

resource "google_compute_global_address" "sql" {
  name          = "${local.name_prefix}-sql"
  project       = var.project
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql.name]

  depends_on = [google_project_service.this]
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "this" {
  name             = "${local.name_prefix}-pg"
  project          = var.project
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.db_tier
    availability_type = var.db_ha ? "REGIONAL" : "ZONAL"
    disk_size         = 20
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.this.id
      # Refuse unencrypted connections server-side; the URLs also carry sslmode=require.
      ssl_mode = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "02:00"
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "app" {
  name     = "app"
  project  = var.project
  instance = google_sql_database_instance.this.name
  charset  = "UTF8"
}

resource "google_sql_user" "app" {
  name     = "app"
  project  = var.project
  instance = google_sql_database_instance.this.name
  password = random_password.db.result
}

# --- Registry ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "this" {
  project       = var.project
  location      = var.region
  repository_id = "${var.project}-${var.environment}"
  format        = "DOCKER"
  description   = "Showcase service images"

  labels = local.labels

  depends_on = [google_project_service.this]
}

# --- Secrets ----------------------------------------------------------------------------

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "google_secret_manager_secret" "jwt_private" {
  project   = var.project
  secret_id = "jwt-private-key"

  replication {
    auto {}
  }

  labels = local.labels
}

resource "google_secret_manager_secret" "jwt_public" {
  project   = var.project
  secret_id = "jwt-public-key"

  replication {
    auto {}
  }

  labels = local.labels
}

resource "google_secret_manager_secret" "database_url" {
  project   = var.project
  secret_id = "database-url"

  replication {
    auto {}
  }

  labels = local.labels
}

resource "google_secret_manager_secret_version" "jwt_private" {
  secret      = google_secret_manager_secret.jwt_private.id
  secret_data = tls_private_key.jwt.private_key_pem
}

resource "google_secret_manager_secret_version" "jwt_public" {
  secret      = google_secret_manager_secret.jwt_public.id
  secret_data = tls_private_key.jwt.public_key_pem
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  secret_data = format(
    "postgresql+psycopg://app:%s@%s:5432/app?sslmode=require",
    random_password.db.result,
    # ipv4_enabled = false, so the only address is the private one.
    google_sql_database_instance.this.private_ip_address,
  )
}

# mTLS certificates are issued and rotated inside the cluster by cert-manager
# (k8s/components/internal-pki) rather than stored in Secret Manager, so this environment
# carries no CA key in state and no manual rotation step. See ADR 0006.

# --- Workload Identity for External Secrets --------------------------------------------
# The Kubernetes service account in the cluster is bound to a Google service account that
# can read these three secrets. No JSON key file exists anywhere.

resource "google_service_account" "eso" {
  project      = var.project
  account_id   = "${var.project}-eso"
  display_name = "External Secrets operator for the showcase cluster"
}

resource "google_secret_manager_secret_iam_member" "eso" {
  # JWT and database secrets -- nothing else in the project. Certificate material is issued
  # in-cluster by cert-manager, so it is not in Secret Manager at all.
  for_each = {
    jwt-private-key = google_secret_manager_secret.jwt_private.secret_id
    jwt-public-key  = google_secret_manager_secret.jwt_public.secret_id
    database-url    = google_secret_manager_secret.database_url.secret_id
  }

  project   = var.project
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.eso.email}"
}

resource "google_service_account_iam_member" "eso_workload_identity" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[external-secrets/external-secrets]"
}
