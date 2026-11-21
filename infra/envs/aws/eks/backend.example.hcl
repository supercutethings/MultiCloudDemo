# Copy to backend.hcl (git-ignored) or generate it from the bootstrap outputs:
#   terraform -chdir=infra/bootstrap/aws output -raw backend_hcl > infra/envs/aws/eks/backend.hcl
bucket         = "showcase-tfstate-111122223333"
key            = "aws/eks/dev.tfstate"
region         = "eu-west-1"
dynamodb_table = "showcase-tfstate-lock"
encrypt        = true
