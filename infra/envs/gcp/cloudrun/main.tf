locals {
  name_prefix = "${var.project}-${var.environment}"

  labels = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
    repository  = "multicloud-iac-showcase"
    runtime     = "cloud-run"
  }

  # Shared, non-secret configuration. The same map the ECS environment and the Container
  # Apps environment build, so the application code cannot tell the clouds apart.
  common_env = {
    ENVIRONMENT  = var.environment
    LOG_LEVEL    = "INFO"
    JWT_ISSUER   = "showcase-auth"
    JWT_AUDIENCE = "showcase-api"
  }

  apis = [
    "compute.googleapis.com",
    "run.googleapis.com",
    "vpcaccess.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "servicenetworking.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  service_names = toset(["auth", "catalog", "gateway"])
}

resource "google_project_service" "this" {
  for_each = toset(local.apis)

  project            = var.project
  service            = each.value
  disable_on_destroy = false
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# One service account per service. This is the GCP answer to the ECS task role and the
# Azure user-assigned identity: the workload's own identity, with only the permissions it
# needs, and no key file anywhere.
resource "google_service_account" "app" {
  for_each = local.service_names

  project      = var.project
  account_id   = "${var.project}-${each.value}"
  display_name = "Showcase ${each.value} (${var.environment})"

  depends_on = [google_project_service.this]
}

module "network" {
  source = "../../../modules/gcp/network"

  project = var.project
  region  = var.region

  name           = "${local.name_prefix}-vpc"
  connector_name = "${var.project}-${var.environment}-conn"
  connector_cidr = var.connector_cidr

  labels = local.labels

  depends_on = [google_project_service.this]
}

module "registry" {
  source = "../../../modules/gcp/artifact_registry"

  project       = var.project
  region        = var.region
  repository_id = "${var.project}-${var.environment}"

  reader_members = [for sa in google_service_account.app : "serviceAccount:${sa.email}"]

  labels = local.labels

  depends_on = [google_project_service.this]
}

module "sql" {
  source = "../../../modules/gcp/cloud_sql"

  project    = var.project
  region     = var.region
  name       = "${local.name_prefix}-pg"
  network_id = module.network.network_id

  database_version = var.database_version
  tier             = var.db_tier
  disk_size_gb     = var.db_disk_size_gb
  ha               = var.db_ha
  password         = random_password.db.result

  deletion_protection = var.deletion_protection
  labels              = local.labels

  depends_on = [google_project_service.this]
}

# Secrets are generated here so a fresh clone works with a single `terraform apply`.
# Rotation: `terraform apply -replace=tls_private_key.jwt`, and Cloud Run picks up the new
# version on the next revision because the reference is `latest`.
module "secrets" {
  source = "../../../modules/gcp/secret_manager"

  project = var.project
  labels  = local.labels

  secrets = {
    "jwt-private-key" = tls_private_key.jwt.private_key_pem
    "jwt-public-key"  = tls_private_key.jwt.public_key_pem
    "database-url"    = module.sql.database_url
  }

  accessors = {
    # Only auth signs tokens, so only auth can read the private key.
    "jwt-private-key" = ["serviceAccount:${google_service_account.app["auth"].email}"]
    "jwt-public-key"  = [for name in ["auth", "catalog", "gateway"] : "serviceAccount:${google_service_account.app[name].email}"]
    "database-url"    = [for name in ["auth", "catalog"] : "serviceAccount:${google_service_account.app[name].email}"]
  }

  depends_on = [google_project_service.this]
}

module "run" {
  source = "../../../modules/gcp/cloud_run"

  project = var.project
  region  = var.region

  connector_id = module.network.connector_id

  # Internal services accept invocations from the gateway's identity and nothing else.
  internal_callers = ["serviceAccount:${google_service_account.app["gateway"].email}"]

  services = {
    auth = {
      image           = "${module.registry.prefix}/auth:${var.image_tag}"
      cpu             = 0.25
      memory          = "512Mi"
      min_instances   = var.service_min_instances
      max_instances   = var.service_max_instances
      port            = 8000
      public          = false
      concurrency     = 40
      service_account = google_service_account.app["auth"].email

      env = merge(local.common_env, { PORT = "8000" })

      secret_env = {
        DATABASE_URL    = module.secrets.secret_ids["database-url"]
        JWT_PRIVATE_KEY = module.secrets.secret_ids["jwt-private-key"]
        JWT_PUBLIC_KEY  = module.secrets.secret_ids["jwt-public-key"]
      }

      upstreams = {}
    }

    catalog = {
      image           = "${module.registry.prefix}/catalog:${var.image_tag}"
      cpu             = 0.25
      memory          = "512Mi"
      min_instances   = var.service_min_instances
      max_instances   = var.service_max_instances
      port            = 8000
      public          = false
      concurrency     = 40
      service_account = google_service_account.app["catalog"].email

      env = merge(local.common_env, { PORT = "8000" })

      secret_env = {
        DATABASE_URL   = module.secrets.secret_ids["database-url"]
        JWT_PUBLIC_KEY = module.secrets.secret_ids["jwt-public-key"]
      }

      upstreams = {}
    }

    gateway = {
      image           = "${module.registry.prefix}/gateway:${var.image_tag}"
      cpu             = 0.25
      memory          = "512Mi"
      min_instances   = var.gateway_min_instances
      max_instances   = var.gateway_max_instances
      port            = 8000
      public          = true
      concurrency     = 80
      service_account = google_service_account.app["gateway"].email

      env = merge(local.common_env, {
        PORT    = "8000"
        GIT_SHA = var.image_tag
      })

      secret_env = {
        JWT_PUBLIC_KEY = module.secrets.secret_ids["jwt-public-key"]
      }

      # Resolved by the module from the real service URIs.
      upstreams = {
        AUTH_SERVICE_URL    = "auth"
        CATALOG_SERVICE_URL = "catalog"
      }
    }
  }

  labels = local.labels

  depends_on = [module.secrets, module.registry]
}
