output "secret_ids" {
  description = "Secret id -> resource name, for a Cloud Run `secret_key_ref`."
  value       = { for name, secret in google_secret_manager_secret.this : name => secret.id }
}

output "secret_names" {
  value = { for name, secret in google_secret_manager_secret.this : name => secret.secret_id }
}
