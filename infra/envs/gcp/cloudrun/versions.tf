terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Bucket from backend.hcl (or -backend-config at init time).
  backend "gcs" {
    prefix = "gcp/cloudrun/dev"
  }
}

provider "google" {
  project = var.project
  region  = var.region
}
