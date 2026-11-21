# Test root. It declares the providers so that the mock providers in `contract.tftest.hcl`
# can stand in for real clouds; every `run` block targets a module under `infra/` with
# `module { source = ... }`. Nothing here can reach an account, create a resource or spend
# money -- that is the point of using mocks rather than a throwaway subscription.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
