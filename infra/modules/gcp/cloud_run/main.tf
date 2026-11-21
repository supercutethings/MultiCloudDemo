# Cloud Run runtime for the serverless leg.
#
# Two resources instead of one, for the same reason the Container Apps module splits them:
# the gateway's upstream URLs are the *real* service URIs, which are computed attributes.
# Referencing them from inside the same `for_each` resource would be a cycle, so the
# internal services are created first and the public ones read their `uri`.
#
# `INGRESS_TRAFFIC_INTERNAL_ONLY` means "reachable from the VPC or from a Google load
# balancer", not "reachable from anywhere in the project". The gateway gets through because
# all of its egress goes through the Serverless VPC Access connector. A request from the
# public internet is rejected by the front end before IAM is even consulted.
#
# The transport note is the same as on Azure and for the same reason: Cloud Run terminates
# TLS and forwards plaintext to the container, with no client-certificate passthrough. The
# internal hop is HTTP inside the VPC, not application-level mTLS. Recorded in
# docs/cloud-matrix.md.

locals {
  internal = { for name, service in var.services : name => service if !service.public }
  public   = { for name, service in var.services : name => service if service.public }

  internal_env = {
    for name, service in local.internal : name => concat(
      [for key, value in service.env : { name = key, value = value, secret = null }],
      [for key, secret in service.secret_env : { name = key, value = null, secret = secret }],
    )
  }

  public_env = {
    for name, service in local.public : name => concat(
      [for key, value in service.env : { name = key, value = value, secret = null }],
      [for key, secret in service.secret_env : { name = key, value = null, secret = secret }],
      [
        for key, upstream in service.upstreams : {
          name   = key
          value  = google_cloud_run_v2_service.internal[upstream].uri
          secret = null
        }
      ],
    )
  }

  caller_pairs = merge([
    for name, _ in local.internal : {
      for caller in var.internal_callers : "${name}|${caller}" => { service = name, member = caller }
    }
  ]...)
}

resource "google_cloud_run_v2_service" "internal" {
  for_each = local.internal

  name     = each.key
  project  = var.project
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  labels = var.labels

  template {
    service_account = each.value.service_account

    vpc_access {
      connector = var.connector_id
      # ALL_TRAFFIC so database traffic leaves through the connector too; with the default
      # (PRIVATE_RANGES_ONLY) Cloud SQL's private address is not routed.
      egress = "ALL_TRAFFIC"
    }

    scaling {
      min_instance_count = each.value.min_instances
      max_instance_count = each.value.max_instances
    }

    max_instance_request_concurrency = each.value.concurrency

    containers {
      image = each.value.image

      ports {
        container_port = each.value.port
      }

      resources {
        limits = {
          cpu    = tostring(each.value.cpu)
          memory = each.value.memory
        }

        # CPU is allocated during requests only, which is what makes an idle service free.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = local.internal_env[each.key]

        content {
          name  = env.value.name
          value = env.value.value

          dynamic "value_source" {
            for_each = env.value.secret == null ? [] : [env.value.secret]

            content {
              secret_key_ref {
                secret  = value_source.value
                version = "latest"
              }
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = each.value.port
        }

        initial_delay_seconds = 5
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 12
      }

      liveness_probe {
        http_get {
          path = "/readyz"
          port = each.value.port
        }

        timeout_seconds   = 3
        period_seconds    = 15
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

resource "google_cloud_run_v2_service" "public" {
  for_each = local.public

  name     = each.key
  project  = var.project
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  labels = var.labels

  template {
    service_account = each.value.service_account

    vpc_access {
      connector = var.connector_id
      egress    = "ALL_TRAFFIC"
    }

    scaling {
      min_instance_count = each.value.min_instances
      max_instance_count = each.value.max_instances
    }

    max_instance_request_concurrency = each.value.concurrency

    containers {
      image = each.value.image

      ports {
        container_port = each.value.port
      }

      resources {
        limits = {
          cpu    = tostring(each.value.cpu)
          memory = each.value.memory
        }

        cpu_idle          = true
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = local.public_env[each.key]

        content {
          name  = env.value.name
          value = env.value.value

          dynamic "value_source" {
            for_each = env.value.secret == null ? [] : [env.value.secret]

            content {
              secret_key_ref {
                secret  = value_source.value
                version = "latest"
              }
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = each.value.port
        }

        initial_delay_seconds = 5
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 12
      }

      liveness_probe {
        http_get {
          path = "/readyz"
          port = each.value.port
        }

        timeout_seconds   = 3
        period_seconds    = 15
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# The only unauthenticated entrypoint in the project.
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = local.public

  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.public[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Internal services are private: the gateway's service account is the only caller allowed.
resource "google_cloud_run_v2_service_iam_member" "internal_callers" {
  for_each = local.caller_pairs

  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.internal[each.value.service].name
  role     = "roles/run.invoker"
  member   = each.value.member
}
