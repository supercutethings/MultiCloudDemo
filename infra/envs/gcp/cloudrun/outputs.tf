output "url" {
  description = "Public gateway URL. Pass to `make smoke LOCAL_URL=...`."
  value       = module.run.urls["gateway"]
}

output "internal_urls" {
  description = "Service URIs for auth and catalog. Reachable only through the connector."
  value = {
    auth    = module.run.urls["auth"]
    catalog = module.run.urls["catalog"]
  }
}

output "image_repository_prefix" {
  description = "Prefix for image references, e.g. `docker tag auth <prefix>/auth:<sha>`."
  value       = module.registry.prefix
}

output "connector_id" {
  description = "Serverless VPC Access connector used by every service."
  value       = module.network.connector_id
}

output "database_connection_name" {
  value = module.sql.connection_name
}

output "service_accounts" {
  description = "Service name -> service account email."
  value       = { for name, sa in google_service_account.app : name => sa.email }
}

output "project_id" {
  value = var.project
}

output "region" {
  value = var.region
}
