# Cloud SQL with a private IP only.
#
# The address comes from a peering range allocated out of the VPC, so there is no public
# endpoint to misconfigure and no authorised-network list to maintain. Cloud Run reaches it
# through the Serverless VPC Access connector, never through the internet.

resource "google_compute_global_address" "private" {
  name          = "${var.name}-sql"
  project       = var.project
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = var.network_id
}

resource "google_service_networking_connection" "private" {
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private.name]
}

resource "google_sql_database_instance" "this" {
  name                = var.name
  project             = var.project
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = var.ha ? "REGIONAL" : "ZONAL"
    disk_size         = var.disk_size_gb
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      # Refuse plaintext server-side; the connection string also carries sslmode=require, so
      # a client cannot opt out even by editing the URL.
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

    user_labels = var.labels
  }

  depends_on = [google_service_networking_connection.private]
}

resource "google_sql_database" "app" {
  name     = var.database_name
  project  = var.project
  instance = google_sql_database_instance.this.name
  charset  = "UTF8"
}

resource "google_sql_user" "app" {
  name     = var.user_name
  project  = var.project
  instance = google_sql_database_instance.this.name
  password = var.password
}
