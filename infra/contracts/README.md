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

| Contract concept | AWS (implemented) | Azure (implemented) | GCP (planned) |
|---|---|---|---|
| Public entrypoint | ALB + HTTPS listener | Container Apps ingress (platform TLS) | Global HTTPS LB |
| Compute | ECS Fargate | Container Apps (consumption, scale to zero) | Cloud Run |
| Service discovery | Cloud Map private DNS | Container Apps internal ingress FQDN | Cloud Run internal URL |
| Database | RDS PostgreSQL | Flexible Server, delegated subnet | Cloud SQL |
| Secrets | Secrets Manager | Key Vault (one secret per value, RBAC) | Secret Manager |
| Registry | ECR (immutable tags) | ACR (admin account disabled) | Artifact Registry |
| Workload identity | ECS task role | User-assigned managed identity per app | Runtime service account |

Azure fills every row, with one deliberate difference: Container Apps ingress terminates TLS
and forwards plaintext to the container, so the internal hop is HTTP inside the environment
instead of application-level mTLS. That gap is recorded in `docs/cloud-matrix.md`.

The parity tests in `tests/terraform/` (Phase 4) assert that a module exposes every output
above, so the contract cannot rot without a red build.
