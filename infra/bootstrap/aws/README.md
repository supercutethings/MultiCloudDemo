# AWS bootstrap (run once, by a human with admin rights)

Creates the things Terraform cannot manage about itself:

* the S3 bucket that holds remote state (versioned, encrypted, TLS-only),
* the DynamoDB table that provides state locking,
* the GitHub OIDC provider and the IAM role that CI assumes -- **no long-lived AWS keys
  are ever stored in GitHub.**

State for this stack stays local (`bootstrap/terraform.tfstate`). It is small, changes
almost never, and keeping it out of the very bucket it creates avoids the classic
chicken-and-egg problem. Keep the file safe; it contains no secrets.

## Usage

```bash
cd infra/bootstrap/aws
terraform init
terraform apply -var="github_org=<your-github-user-or-org>" -var="github_repo=<repo-name>"

# Generate the backend config for the dev environment:
terraform output -raw backend_hcl > ../../envs/aws/dev/backend.hcl
```

Then add two repository variables (Settings -> Secrets and variables -> Actions ->
Variables) so CI can log in:

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | `terraform output -raw ci_role_arn` |
| `AWS_REGION` | e.g. `eu-west-1` |
| `TF_STATE_BUCKET` | `terraform output -raw state_bucket` |
| `TF_STATE_LOCK_TABLE` | `terraform output -raw lock_table` |

Optionally set `budget_alert_email` to get a monthly AWS Budgets notification -- the
cheapest insurance against forgetting to run `make destroy`.
