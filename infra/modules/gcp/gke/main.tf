# GKE: the third leg. A *regional* cluster, which is the GCP-specific HA primitive: the
# control plane is replicated across zones by Google, and node pools are spread across
# `node_locations`. There is no single-zone control plane to lose.
#
# Security posture:
#   * private nodes + optional private endpoint (no public IPs on nodes);
#   * Workload Identity (the GCP equivalent of IRSA): pods impersonate a GSA, keys never
#     touch the cluster;
#   * Dataplane V2 (eBPF) enforces NetworkPolicy without a per-node daemon;
#   * Binary Authorization in enforce mode, mirroring the Conftest policy gate in CI;
#   * shielded nodes (secure boot + integrity monitoring) and COS_CONTAINERD images.

locals {
  name_prefix = "${var.project}-${var.environment}"

  labels = merge(
    {
      project     = var.project
      environment = var.environment
      managed_by  = "terraform"
    },
    var.labels,
  )
}

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  project  = var.project
  location = var.region

  network    = var.network
  subnetwork = var.subnetwork

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Regional control plane + nodes in every listed zone.
  node_locations = var.zones

  # One node pool, described explicitly below, so its autoscaling and upgrade settings are
  # reviewable instead of hidden in the default pool.
  remove_default_node_pool = true
  initial_node_count       = 1

  datapath_provider     = "ADVANCED_DATAPATH"
  enable_shielded_nodes = true

  vertical_pod_autoscaling {
    enabled = true
  }

  release_channel {
    channel = var.release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.enable_private_endpoint
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  deletion_protection = var.deletion_protection

  resource_labels = local.labels
}

resource "google_container_node_pool" "general" {
  name     = "general"
  project  = var.project
  cluster  = google_container_cluster.this.id
  location = var.region

  node_locations = var.zones

  # Cluster Autoscaler (built into GKE) scales between these bounds, per zone. min 1 means
  # the pool never disappears entirely, so a zone loss cannot make the cluster unschedulable.
  autoscaling {
    min_node_count = var.min_nodes_per_zone
    max_node_count = var.max_nodes_per_zone
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    image_type   = "COS_CONTAINERD"

    disk_size_gb = 50
    disk_type    = "pd-balanced"

    labels = {
      role = "general"
    }

    tags = ["gke-node"]

    # cloud-platform scope + Workload Identity: the node has a broad token, but pods can
    # only impersonate a GSA they are explicitly bound to through a KSA.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
