output "urls" {
  description = "Service name -> URL. Internal services are only reachable through the connector."
  value = merge(
    { for name, service in google_cloud_run_v2_service.internal : name => service.uri },
    { for name, service in google_cloud_run_v2_service.public : name => service.uri },
  )
}

output "service_names" {
  value = merge(
    { for name, service in google_cloud_run_v2_service.internal : name => service.name },
    { for name, service in google_cloud_run_v2_service.public : name => service.name },
  )
}
