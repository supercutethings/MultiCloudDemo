# CI: what runs, what it needs, and how it authenticates

Three workflows, each with a different job:

| Workflow | Trigger | Cloud credentials |
|---|---|---|
| `apps-ci` | push, pull request | none — build, test, lint, image scan |
| `k8s-validate` | push, pull request (manifests, policies) | none — render, `kubeconform -strict`, `conftest` |
| `terraform-plan` | pull request (`infra/**`, `platform/**`), manual | OIDC, optional per cloud |
| `terraform-apply` | push to `main`, manual | OIDC, optional per cloud |
| `terraform-drift` | daily schedule, manual | OIDC, optional per cloud — an empty plan is the green case |
| `terraform-ephemeral` | manual only | OIDC; creates a throwaway environment and destroys it in the same run |

The `validate` job inside `terraform-plan` runs on every pull request with **no credentials
at all**: `terraform fmt -check` plus `init -backend=false` and `validate` in every module and
environment. That is why a fresh clone with no cloud account still has a meaningful red/green
signal.

The `contract` job beside it is equally credential-free: it runs `terraform test` against
mocked providers and asserts the module contract ([Contract tests](#contract-tests)).

## Why OIDC and not a secret

A stored cloud key is a long-lived credential that works from anywhere until somebody
notices it leaked. A GitHub OIDC token is valid for minutes, is issued only to a job in this
repository, and is scoped by its `sub` claim:

```
repo:OWNER/REPO:pull_request          # a PR job (plan)
repo:OWNER/REPO:ref:refs/heads/main   # a manual run on main
repo:OWNER/REPO:environment:azure-dev # a job that declares `environment: azure-dev`
```

Those three subjects are the only ones that can exchange a token for cloud credentials.
A fork's pull request gets `pull_request` from *its* repository, which does not match, so a
fork cannot assume the role. Rationale: [ADR 0002](adr/0002-oidc-no-static-credentials.md).

## AWS

`infra/bootstrap/aws` creates the state bucket, the lock table and the role, and prints the
values:

```
AWS_ROLE_ARN           arn:aws:iam::<account>:role/<project>-github-actions
AWS_REGION             eu-west-1
TF_STATE_BUCKET        <project>-tfstate-<suffix>
TF_STATE_LOCK_TABLE    <project>-tfstate-lock
```

The plan job assumes the role with `aws-actions/configure-aws-credentials`; the apply job
does the same but additionally requires approval on the `aws-dev` environment.

## Azure

One command, once, as an owner of the subscription:

```bash
scripts/azure-oidc-bootstrap.sh --owner <org> --repo <repo>
```

It creates the state account, the app registration, the three federated credentials and the
role assignments, then prints the repository variables:

```
AZURE_CLIENT_ID                 app registration (client) id
AZURE_TENANT_ID                 tenant id
AZURE_SUBSCRIPTION_ID           subscription id
AZURE_TFSTATE_RESOURCE_GROUP    resource group holding the state account
AZURE_TFSTATE_STORAGE_ACCOUNT   storage account name
AZURE_TFSTATE_CONTAINER         blob container name
```

Two details that cost time if you meet them for the first time:

* **`User Access Administrator` is required, not optional.** The modules create role
  assignments (AcrPull, Key Vault Secrets User, deployer access to the vault). A principal
  with only `Contributor` gets through the network and the database, then fails on the first
  `azurerm_role_assignment` with `AuthorizationFailed`. Assign both roles.
* **The apply job needs its own federated credential.** A job that declares
  `environment: azure-dev` presents `repo:OWNER/REPO:environment:azure-dev`, not
  `ref:refs/heads/main`. The bootstrap script creates both.

The azurerm provider picks up the CLI session that `azure/login@v2` establishes, so no
provider-level credentials are configured anywhere in the Terraform.

State locking is a blob lease: the `azurerm` backend locks the state blob for the duration of
the run, which is why Azure needs no equivalent of the DynamoDB table.

## GCP

`infra/bootstrap/gcp` creates the state bucket, the Workload Identity Federation pool and
its GitHub provider, and the service account the workflows impersonate. It prints exactly
the values the jobs read:

```
GCP_PROJECT_ID                   project id (not the display name)
GCP_REGION                       europe-west1
GCP_TF_STATE_BUCKET              <project>-tfstate-<project-number>
GCP_WORKLOAD_IDENTITY_PROVIDER   projects/<number>/locations/global/workloadIdentityPools/.../providers/github-actions
GCP_SERVICE_ACCOUNT              <project>-github-actions@<project>.iam.gserviceaccount.com
```

Three details that cost time if you meet them for the first time:

* **The attribute condition is the security boundary.** `assertion.repository == "ORG/REPO"`
  is what stops every other GitHub repository on the internet from using the pool; without
  it the pool is world-writable and the `principalSet` binding becomes irrelevant. The AWS
  trust policy does the same job with a `sub` condition.
* **`roles/iam.serviceAccountUser` is required**, and it is not implied by
  `serviceAccountAdmin`. The apply creates Cloud Run revisions that *run as* the per-service
  accounts; without this role the handshake succeeds and the revision creation fails with a
  permission error that names neither role.
* **`iamcredentials.googleapis.com` must be enabled.** The federation exchange itself uses
  `sts.googleapis.com`, but impersonating the service account afterwards is a separate API.
  The bootstrap stack enables both, so this is a note for a project set up by hand.

State locking: the `gcs` backend in Terraform 1.9 does not lock, so there is no GCS
counterpart to the DynamoDB table or the blob lease. Concurrency is prevented by the
workflow's `concurrency: tf-apply` group, which is weaker than a real lock and is documented
here rather than assumed away.

## Gating

All three cloud jobs are gated on their variables existing:

```yaml
if: vars.AWS_ROLE_ARN != ''
if: vars.AZURE_CLIENT_ID != ''
if: vars.GCP_WORKLOAD_IDENTITY_PROVIDER != ''
```

A repository with neither set runs only `validate`, and the workflows stay green while
reporting "nothing to deploy" instead of failing on a missing variable. This is deliberate:
the repository has to be useful to someone who has cloned it and has no cloud account yet.

## Apply order

Both apply jobs are two-phase for the same reason: an image has to exist before a workload
that references it can start.

```
apply -target=module.ecr       →  build and push images  →  apply -var image_tag=<sha>  →  smoke
apply -target=module.acr       →  build and push images  →  apply -var image_tag=<sha>  →  smoke
apply -target=module.registry  →  build and push images  →  apply -var image_tag=<sha>  →  smoke
```

`image_tag` is the commit SHA, never `latest`, so the deployed revision is traceable to a
commit and a re-run of the same commit is a no-op rather than a silent redeploy.

## Contract tests

`tests/terraform/` runs `terraform test` against **mocked** AWS, Azure and GCP providers and
asserts the contract in `infra/contracts/README.md`: an internal URL, a public URL, a log
destination, and one workload identity per app. No credentials, no account, a few seconds.

```bash
cd tests/terraform && terraform init -backend=false && terraform test
```

It is not ceremony. On its first run it caught `transport = "Http"` in the Container Apps
module — a value `terraform validate` accepts and the provider rejects at apply time, which
is exactly the class of mistake that otherwise surfaces twenty minutes into a deploy.

## Drift detection

`terraform-drift` plans every environment that has credentials, daily at 05:17 UTC, with
`-detailed-exitcode`:

| Exit code | Meaning | What the workflow does |
|---|---|---|
| 0 | no changes | closes the drift issue if one is open |
| 2 | drift | opens or refreshes one issue per environment |
| 1 | the plan failed | fails the job — an error is not drift |

One issue per environment, updated in place and closed automatically once the plan is empty
again. The workflow covers AWS and Azure; GCP gained plan and apply jobs first, and its drift
job is the next one to add now that the federation pool exists.

## Ephemeral environment

`terraform-ephemeral` is manual only, because it is the one workflow that spends money by
existing. It creates an environment, smoke-tests it, and destroys it — with the destroy in
an `if: always()` step, so a failed smoke test still tears it down.

Two details keep it away from the standing environment: it initialises a **separate state
key** (`ephemeral/terraform.tfstate`), so `destroy` can only delete what the run created,
and it passes `-var environment=ephemeral`, so no resource name collides. The final
`plan -detailed-exitcode` must return 0, which is the only proof that the destroy actually
removed everything.

## Running a plan by hand

```bash
cd infra/envs/azure/dev
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform show -json tfplan > plan.json
conftest test plan.json -p ../../../platform/policies
```

The policy step is the same one CI runs, and it is the reason a plan that opens a port to the
world fails before it can be applied.
