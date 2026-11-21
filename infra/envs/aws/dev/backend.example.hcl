# Copy to backend.hcl (git-ignored) or generate it with:
#   terraform -chdir=infra/bootstrap/aws output -raw backend_hcl > infra/envs/aws/dev/backend.hcl
bucket         = "showcase-tfstate-123456789012"
dynamodb_table = "showcase-tfstate-lock"
region         = "eu-west-1"
encrypt        = true
