# The multicloud module contract

Every provider implements the same interface so that `terraform plan` output, CI jobs and
the smoke test are provider-agnostic. If a module cannot satisfy a field, it returns the
closest native equivalent and the gap is recorded in `docs/cloud-matrix.md` -- it is never
silently dropped.

## Inputs (per service)

| Name | Type | Notes |
|---|---|---|
| `name` | `string` | `auth` \| `catalog` \| `gateway` |
| `environment` | `string` | `dev` \| `staging` \| `prod` |
| `image` | `string` | Fully qualified image reference, ideally by digest |
| `cpu` / `memory` | `number` | vCPU units and MiB |
| `desired_count` | `number` | Baseline replica count |
| `container_port` | `number` | 8000 for all three services |
| `environment_variables` | `map(string)` | Non-secret configuration |
| `secret_environment_variables` | `map(string)` | Env var name -> provider secret reference |
| `public` | `bool` | Only `gateway` is true |

## Outputs (per service)

| Name | Meaning |
|---|---|
| `service_url` | Internal URL other services use (DNS name in the VPC/VNet) |
| `public_url` | Only set when `public = true` |
| `log_group_id` | Queryable log destination |
| `workload_identity_id` | IAM role / managed identity / service account used by the workload |

## Provider mapping (implemented status)

| Contract concept | AWS | Azure | GCP |
|---|---|---|---|
| Public entrypoint | ALB + HTTPS listener | Container Apps ingress (platform TLS) | Cloud Run URL (`*.run.app`, managed TLS) |
| Compute | ECS Fargate | Container Apps (consumption, scale to zero) | Cloud Run (gen2, scale to zero) |
| Service discovery | Cloud Map private DNS | Container Apps internal ingress FQDN | Internal-only service URI through the VPC connector |
| Database | RDS PostgreSQL | Flexible Server, delegated subnet | Cloud SQL, private IP via VPC peering |
| Secrets | Secrets Manager | Key Vault (one secret per value, RBAC) | Secret Manager (one secret per value) |
| Registry | ECR (immutable tags) | ACR (admin account disabled) | Artifact Registry (cleanup policy, no `latest`) |
| Workload identity | ECS task role | User-assigned managed identity per app | Service account per service |
| Logs | CloudWatch | Log Analytics | Cloud Logging |

All three implement the table. Two differences are deliberate and recorded rather than
hidden:

* **Transport behind the edge.** Container Apps and Cloud Run terminate TLS at the platform
  and forward plaintext to the container, with no client-certificate passthrough. So the
  gateway -> auth/catalog hop is HTTP *inside* the VNet/VPC on those two legs, not the
  application-level mTLS that ECS and Kubernetes use. The boundary holds everywhere; the
  transport guarantee does not.
* **Public entrypoint.** AWS uses an ALB because ECS has no ingress of its own. Azure and
  GCP use the platform ingress, which is free and terminates TLS. The global HTTPS load
  balancer described in `docs/cloud-matrix.md` is an optional extra (~$18/month) that this
  repository does not deploy, because it buys no capability the contract needs.

`tests/terraform/` asserts this table against mocked providers — internal URL, public URL,
log destination, one identity per app — so the contract cannot rot without a red build:

```bash
cd tests/terraform && terraform init -backend=false && terraform test
```

It runs with no credentials and in a few seconds, which is why it is cheap enough to run on
every pull request rather than once a quarter.
