# The GCP serverless leg needs one piece of network plumbing the other legs do not: a
# Serverless VPC Access connector. Cloud Run has no address inside the VPC, so without the
# connector it cannot reach a private Cloud SQL instance or an internal-only service.
#
# This is the step most "Cloud Run + Cloud SQL" tutorials skip, and the one that fails at
# apply time with a permission error that looks like a bug in the module.

resource "google_compute_network" "this" {
  name                    = var.name
  project                 = var.project
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_vpc_access_connector" "this" {
  name          = var.connector_name
  project       = var.project
  region        = var.region
  network       = google_compute_network.this.name
  ip_cidr_range = var.connector_cidr

  # Two instances is the floor that keeps a cold start short: one instance cannot hold a
  # connection open while another is being created.
  min_instances = var.connector_min_instances
  max_instances = var.connector_max_instances
}
