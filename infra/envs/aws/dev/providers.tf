provider "aws" {
  region = var.region

  # Applied to every resource that supports tags, so the cost explorer can group
  # spend by project and environment without per-resource effort.
  default_tags {
    tags = local.tags
  }
}
