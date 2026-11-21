terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Partial configuration: bucket, table and region come from backend.hcl, produced by
  # `terraform output -raw backend_hcl` in infra/bootstrap/aws. Keeping them out of git
  # means the same code works in any account without editing a file.
  backend "s3" {
    key     = "showcase/aws/dev/terraform.tfstate"
    encrypt = true
  }
}
