output "state_bucket" {
  description = "S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.lock.name
}

output "ci_role_arn" {
  description = "Role GitHub Actions assumes via OIDC. Set as the AWS_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions.arn
}

output "region" {
  description = "Region the backend lives in."
  value       = var.region
}

output "backend_hcl" {
  description = "Ready-to-use partial backend configuration for an environment root."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.bucket}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    region         = "${var.region}"
    encrypt        = true
  EOT
}
