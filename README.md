# Multicloud IaC Showcase

[![apps CI](https://github.com/supercutethings/MultiCloudDemo/actions/workflows/apps-ci.yml/badge.svg)](https://github.com/supercutethings/MultiCloudDemo/actions/workflows/apps-ci.yml)
[![manifests](https://github.com/supercutethings/MultiCloudDemo/actions/workflows/k8s-validate.yml/badge.svg)](https://github.com/supercutethings/MultiCloudDemo/actions/workflows/k8s-validate.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![terraform: 1.9+](https://img.shields.io/badge/terraform-1.9%2B-844FBA.svg)](infra)
[![python: 3.12](https://img.shields.io/badge/python-3.12-3776AB.svg)](apps)

One microservice platform, deployed the same way to **AWS, Azure and GCP** with Terraform.
JWT authentication, a load balancer in front of the only public service, managed
PostgreSQL, secrets in each provider's secret manager, mutual TLS between services, and CI
that authenticates with short-lived OIDC tokens instead of stored cloud keys.

The point is not "Terraform can talk to three providers." The point is that **the
application is constant and the platform is the variable**, so every difference in cost,
IAM model, networking and operational surface has exactly one cause: the provider.

```
Client ──HTTPS──▶ Load balancer ──▶ gateway ──┬──▶ auth     ──┐
                                              └──▶ catalog  ──┴──▶ PostgreSQL
                                        (only the gateway is internet-facing)
```

## Contents

- [Status](#status)
- [Architecture](#architecture)
- [Quick start](#quick-start-2-minutes)
- [Deploy to AWS](#deploy-to-aws)
- [Deploy to Kubernetes](#deploy-to-kubernetes-eks--aks--gke)
- [Internal mutual TLS](#internal-mutual-tls)
- [Security decisions](#security-decisions-worth-a-look)
- [Cost](#cost-in-one-table)
- [Releases](#releases)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Architecture decisions](#decisions)
- [License](#license)

## Status

| Runtime | Cloud | Status | Where |
|---|---|---|---|
| ECS Fargate + ALB | AWS | ✅ end-to-end (RDS, Cloud Map, OIDC CI) | `infra/envs/aws/dev` |
| EKS + ALB Ingress | AWS | ✅ cluster, HPA + autoscaler, 3-AZ | `infra/envs/aws/eks`, `k8s/overlays/eks` |
| AKS + App Gateway | Azure | ✅ cluster, node autoscaler, 3-AZ | `infra/envs/azure/aks`, `k8s/overlays/aks` |
| GKE regional + GCLB | GCP | ✅ cluster, node autoscaler, 3-zone | `infra/envs/gcp/gke`, `k8s/overlays/gke` |
| Container Apps | Azure | 🚧 Phase 2 — serverless leg | `infra/modules/azure` (next) |
| Cloud Run | GCP | 🚧 Phase 3 — serverless leg | `infra/modules/gcp` (next) |

Honest status beats a green badge. What exists runs; what does not is labelled.

## Architecture

```mermaid
flowchart LR
  client[Client] -->|HTTPS| lb["Load balancer<br/>ALB / Container Apps / Global LB"]
  lb --> gw["gateway<br/>public, JWT check"]
  gw -->|/auth/*| auth["auth<br/>internal"]
  gw -->|/catalog/*| cat["catalog<br/>internal"]
  auth --> db[("PostgreSQL<br/>private")]
  cat --> db
  auth -.signs RS256.-> kv[("Secret manager")]
  gw -.verifies.-> kv
```

Three services, one job each:

| Service | Responsibility | Why it exists |
|---|---|---|
| `gateway` | Validates JWTs, adds request ids, proxies | A single, auditable edge — see [ADR 0003](docs/adr/0003-gateway-at-the-edge.md) |
| `auth` | Register, login, refresh; holds the **only** copy of the signing key | RS256 means verifiers never need the private key |
| `catalog` | CRUD scoped to the token's user id | Shows authorisation, not just authentication |

Everything else is infrastructure: VPC with public/private tiers and chained security
groups, TLS listener, target group health checks on `/readyz`, Cloud Map DNS for
service-to-service calls, one IAM role per workload, and secrets injected at container
start — never baked into an image or a task definition.

## Quick start (2 minutes)

Requires Docker, `make`, `openssl`, `jq`.

```bash
make up      # builds the three images, starts Postgres, gateway on :8080
make smoke   # register -> login -> authenticated CRUD through the gateway
make down
```

`make smoke` is the same script CI runs against the deployed load balancer, so a local
pass and a cloud pass mean the same thing.

Run the test suite and the linter the same way CI does:

```bash
make test    # 36 unit tests, including real TLS handshakes
make lint    # ruff
make certs-expiry   # fail if any local certificate is within 7 days of expiry
```

## Deploy to AWS

```bash
# 1. one-time bootstrap: state bucket, lock table, GitHub OIDC role
cd infra/bootstrap/aws
terraform init
terraform apply -var="github_org=<you>" -var="github_repo=<repo>"

# 2. point the dev environment at that state
terraform output -raw backend_hcl > ../../envs/aws/dev/backend.hcl

# 3. add repository variables for CI: AWS_ROLE_ARN, AWS_REGION,
#    TF_STATE_BUCKET, TF_STATE_LOCK_TABLE (values from `terraform output`)

# 4. push to main: the apply workflow builds, pushes and deploys the images,
#    then smoke-tests the load balancer URL.
```

Manual deploy without CI:

```bash
cd infra/envs/aws/dev
terraform init -backend-config=backend.hcl
terraform apply -target=module.ecr                  # registries first
# build + push the three images tagged with a commit SHA...
terraform apply -var="image_tag=<sha>"
make smoke LOCAL_URL="$(terraform output -raw url)"
```

**Then `make destroy`.** The stack costs ≈ $95/month if you forget —
see [docs/cost.md](docs/cost.md) for the full breakdown, the surprisingly patchy free tier,
and seven cheaper alternatives (2-hour demo: **$0.26**).

## Deploy to Kubernetes (EKS / AKS / GKE)

Same images, same env vars, same smoke test. One provider-neutral base and three overlays;
only the ingress, the secret store and the cluster change.

```bash
cd infra/envs/aws/eks && terraform init && terraform apply   # or azure/aks, gcp/gke
export CLUSTER_NAME=showcase-dev-k8s AWS_REGION=eu-west-1 VPC_ID=vpc-... \
       ESO_ROLE_ARN=... ALB_ROLE_ARN=... CA_ROLE_ARN=...
scripts/cluster-addons.sh eks                                  # cert-manager, Reloader, ESO, autoscaler, ALB

export IMAGE_REPO=$(terraform output -raw image_repository_prefix) \
       SECRETS_PREFIX=showcase/dev VPC_CIDR=10.20.0.0/16 CERTIFICATE_ARN=arn:aws:acm:...
bash scripts/k8s-render.sh eks | kubectl apply -f -            # refuses to render with gaps

make loadtest LOCAL_URL=https://... SCENARIO=login CONCURRENCY=60 DURATION=120
kubectl -n showcase get hpa,deploy,pods -w                     # watch it scale
```

What is there: three-zone node pools, HPA (3→24 gateway) feeding Cluster Autoscaler, PDBs,
topology-spread pods, `restricted` Pod Security Admission, default-deny NetworkPolicies, no
service-account token in any pod, and secrets pulled from each cloud's secret manager by a
federated identity. Zone loss, node drain, pod crash and DB failover are each answered by a
specific control — [the map is here](docs/kubernetes.md#high-availability-what-protects-against-what).

Why it is fair to compare: [ADR 0004](docs/adr/0004-kubernetes-parity.md).

## Internal mutual TLS

The edge is HTTPS; the hop behind it was not. Now the gateway authenticates to auth and
catalog with a client certificate, and both verify it during the TLS handshake on 8443 —
no request handler, router or database dependency ever sees an unauthenticated caller.
Probes use a separate plaintext ops port (8000) that serves `/healthz` and `/readyz` and
nothing else, because neither a kubelet nor a load balancer can present a certificate.

```bash
make certs          # local PKI: server CA, per-caller CA, leaves (.certs/, gitignored)
make up             # compose runs the internal hops over mTLS
make smoke          # full flow through the gateway
make mtls-check     # no certificate, unlisted issuer and plaintext are all rejected
make certs-expiry   # fail if anything is within 7 days of expiry
make loadtest-mtls  # what the handshake costs per new connection
make loadtest-rotate # swap the caller certificate mid-run and watch the allow rule
```

There are **two trust domains, not one CA**. The server CA signs what auth and catalog
present; one client CA per caller identity signs what a caller presents. A service mounts
only the caller CAs it allows (`TLS_CLIENT_CA_DIR`), so a new internal service needs an
explicit allow rule rather than merely a certificate — the check happens during the
handshake, where uvicorn can actually enforce it.

On Kubernetes, **cert-manager issues and rotates the leaves** (30 days, renewed at 10 days,
new key every time), Reloader rolls the pods so the renewal reaches the process, and
Prometheus alerts at 21 and 7 days. The CA keys never reach a workload, so a compromised
pod cannot mint identities. On ECS the same hierarchy comes from `infra/modules/pki`. Why
it is built this way, and what it costs:
[ADR 0005](docs/adr/0005-internal-mutual-tls.md) ·
[ADR 0006](docs/adr/0006-cert-manager-internal-pki.md).

## Repository map

```
apps/         three FastAPI services + shared config, logging, security, db, TLS helpers
  tests/      36 unit tests, including handshake tests against a real listener
k8s/
  base/       namespace, deployments, HPA, PDB, NetworkPolicy (no cloud-specific field)
  components/ internal PKI: cert-manager issuers and certificates, identical per cloud
  overlays/   eks | aks | gke: ingress, secret store, database network policy
  monitoring/ certificate-expiry alerts (applied with MONITORING=1)
infra/
  contracts/  the provider-neutral interface every cloud module must satisfy
  bootstrap/  per-cloud state backend and CI trust (applied once, by a human)
  modules/    reusable provider modules (network, ecr, rds, service, alb, pki, eks)
  envs/       environments composed from modules (aws/dev, aws/eks, azure/aks, gcp/gke)
platform/
  policies/   Conftest rules the plan and the manifests must pass before they can apply
scripts/      local PKI, smoke test, mTLS checks, load test, renderer, add-ons
docs/         ADRs, cloud matrix, cost model, Kubernetes runbook
```

## Security decisions worth a look

* **No static cloud credentials.** GitHub Actions assumes a role via OIDC, pinned to this
  repository's `pull_request`, `main` and `environment:*` subjects — [ADR 0002](docs/adr/0002-oidc-no-static-credentials.md).
* **Only one public service.** The ALB has one target group; `auth` and `catalog` accept
  traffic only from the gateway's security group, and each verifies the JWT anyway.
* **Mutual TLS behind the edge.** Transport identity is verified in the handshake, before
  any application code runs, and the trust bundle is per-service and per-caller.
* **RS256, scrypt, constant-time comparisons.** The private key exists only in the auth
  container; passwords are memory-hard hashes, not SHA-256.
* **Nothing secret in the image or the task definition.** Secrets are resolved by the ECS
  execution role at start-up from Secrets Manager.
* **Least privilege where it is cheap to be.** One task role per service, an execution
  role scoped to two secret ARNs, and a CI role limited to creating `${project}-*` roles.
* **Policy as code in CI.** A plan that opens a port to the world or leaves RDS unencrypted
  fails before apply (`platform/policies`).

## Cost, in one table

| | Always-on | Ephemeral (2 h demo) | Free tier? |
|---|---|---|---|
| AWS (ECS) | ≈ $95/mo | ≈ $0.26 | No |
| Azure (Container Apps) | ≈ $0–68/mo | ≈ $0.19 | Yes, year one |
| GCP (Cloud Run) | ≈ $13–32/mo | ≈ $0.09 | $300 credit, 90 days |
| **AWS (EKS)** | ≈ $295/mo | ≈ $0.80 | No — control plane + 3 NATs |
| **Azure (AKS)** | ≈ $150/mo | ≈ $0.41 | Control plane is free |
| **GCP (GKE regional)** | ≈ $215/mo | ≈ $0.59 | $300 credit |

Kubernetes costs roughly 2–3× the serverless legs for the same three services: you are
paying for a control plane, a minimum of three nodes and (on AWS) three NAT gateways. That
trade is the point of the comparison, not an accident — [breakdown](docs/cost.md#kubernetes-eks--aks--gke).

Full component-level breakdown and cheaper variants: [docs/cost.md](docs/cost.md).

## Releases

Versions track repository milestones rather than calendar time: each one is a working,
deployable state of the platform, and the changelog records what changed and why.

| Version | Milestone | Highlights |
|---|---|---|
| **v0.3.0** | Internal PKI and mutual TLS | Two trust domains, app-level mTLS on 8443, cert-manager issuance and rotation, Reloader rollout, expiry alerts at 21/7 days, policy rules for `Certificate` hygiene |
| **v0.2.0** | Kubernetes runtime | EKS, AKS and GKE from one base, three-AZ node pools, HPA + node autoscaling, PDBs, default-deny NetworkPolicies, federated secret access, renderer that refuses incomplete overlays |
| **v0.1.0** | AWS serverless leg | FastAPI services, local Compose stack, network/ECR/RDS/ECS/ALB modules, Cloud Map, OIDC CI, Conftest guardrails |

### Changelog

**v0.3.0 — internal PKI and mutual TLS**

* Added `apps/common/tls.py` and `apps/common/serve.py`: TLS material from files or inline
  PEM, client CA bundles from a directory, `CERT_REQUIRED` by default, fail-closed start-up.
* Split the data plane (8443, mTLS) from the ops plane (8000, `/healthz` and `/readyz` only).
* Added `k8s/components/internal-pki`: self-signed bootstrap → server CA and per-caller
  client CA → 30-day leaves with `rotationPolicy: Always`, renewed 10 days before expiry.
* Added `k8s/monitoring/certificates.yaml`: alerts at 21 and 7 days, `NotReady`
  certificates, CA younger than a year, plus a ServiceMonitor for cert-manager.
* Added `scripts/mtls-check.sh`, `scripts/cert-expiry.sh` and the `handshake` / `rotate`
  load-test scenarios.
* Added Conftest rules for certificate hygiene and for Reloader on Secret volumes.
* Documented the decision in [ADR 0006](docs/adr/0006-cert-manager-internal-pki.md).

**v0.2.0 — Kubernetes runtime**

* Provider-neutral `k8s/base` with `restricted` PSA, HPA v2, PDBs, topology spread and
  default-deny NetworkPolicies.
* Three overlays with a renderer (`scripts/k8s-render.sh`) that fails on any unresolved
  placeholder instead of applying a half-filled manifest.
* `scripts/cluster-addons.sh` per cloud: cert-manager and Reloader everywhere, plus the
  autoscaler, ALB controller and metrics-server only where the provider does not ship them.
* `docs/kubernetes.md`: topology, autoscaling behaviour, HA map, and an explicit
  "verified vs. not verified" section.

**v0.1.0 — AWS serverless leg**

* Three FastAPI services with RS256 JWTs, scrypt password hashing and request-scoped logs.
* Reusable Terraform modules (network, ECR, RDS, ECS service, ALB) behind a contract.
* GitHub Actions: build/test/lint, image scan, `terraform plan` with policy checks, and an
  OIDC-authenticated apply that smoke-tests the deployed URL.

### Unreleased

* Phase 2 — Azure Container Apps leg (see the roadmap).
* Phase 3 — GCP Cloud Run leg.
* Phase 4 — `terraform test` for the contract, drift detection, k6 through the load
  balancer, JWT key-rotation runbook.

## Roadmap

* **Phase 1 — AWS (done):** app, local stack, network/ECR/RDS/ECS/ALB modules, OIDC CI, policies.
* **Phase 1.5 — Kubernetes (done):** EKS, AKS and GKE with three-AZ node pools, HPA + node
  autoscaling, PDBs, default-deny NetworkPolicies, federated secret access, load test.
* **Phase 2 — Azure serverless:** same contract on Container Apps + Flexible Server + Key Vault.
* **Phase 3 — GCP serverless:** Cloud Run + Cloud SQL + Secret Manager; matrix filled in.
* **Phase 4 — Hardening:** `terraform test` for the contract, ephemeral-environment apply in CI,
  drift detection, k6 load test through the LB, JWT key rotation runbook.
* **Phase 5 — Packaging:** recorded demo, per-cloud cost screenshots, "what I would change at
  10× traffic" write-up.

## Contributing

Contributions are welcome — from a typo in a runbook to a whole new cloud leg. The project
is deliberately small enough that a first pull request does not require reading everything.

### Good first contributions

| Area | What would help | Where to start |
|---|---|---|
| Documentation | Fix a stale command, clarify a runbook step, add a diagram | `docs/` |
| Cost model | Re-measure a line item and update the table with the date you measured | `docs/cost.md` |
| Tests | Cover the auth error paths, add a Compose-level smoke variant | `apps/tests/` |
| Policies | New Conftest rule with a failing and a passing fixture | `platform/policies/` |
| Kubernetes | Add a `kustomize` component for a second internal service | `k8s/components/` |
| Phase 2 / 3 | Container Apps or Cloud Run module that satisfies `infra/contracts` | `infra/modules/` |

### Development setup

```bash
git clone https://github.com/supercutethings/MultiCloudDemo.git
cd MultiCloudDemo
python3.12 -m venv .venv && . .venv/bin/activate
pip install -r apps/auth/requirements.txt -r apps/catalog/requirements.txt \
            -r apps/gateway/requirements.txt pytest ruff

make keys certs     # local RS256 keys and mTLS material, both gitignored
make up             # Postgres + the three services
make smoke          # end-to-end check through the gateway
make test lint      # the same checks CI runs
```

Terraform changes additionally need Terraform ≥ 1.6 (`terraform fmt -check -recursive` and
`terraform validate` in every module), and Kubernetes changes need `kubectl`, `kustomize`,
`kubeconform` and `conftest` — the exact invocations are in `.github/workflows/`.

### Before you open a pull request

1. **Open an issue first** for anything larger than a bug fix or a doc tweak, so the design
   can be agreed before the code exists. Small fixes can go straight to a PR.
2. **Keep the contract intact.** Infrastructure modules must satisfy
   `infra/contracts`; if a change needs a new output or variable, change the contract and
   every implementation in the same PR.
3. **Record decisions, not just diffs.** Anything that changes a trust boundary, a
   provider's role in the architecture or an operational assumption gets an ADR in
   `docs/adr/` (copy the format of an existing one; status starts as `proposed`).
4. **Run the checks locally:** `make test lint`, plus `make k8s-render CLOUD=eks` and
   `bash scripts/cert-expiry.sh` when you touch manifests or certificates.
5. **Update the changelog** in the *Unreleased* section above and, if you add a capability,
   the status table and [docs/cloud-matrix.md](docs/cloud-matrix.md).

### Commit and branch conventions

* Branches: `feat/<short-name>`, `fix/<short-name>`, `docs/<short-name>`.
* Commits follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(k8s): ...`, `fix(apps): ...`, `docs(cost): ...`. One logical change per commit;
  a reviewer should be able to revert it on its own.
* Write the *why* in the body when the diff alone does not explain it. "Bump the timeout"
  is a diff; "the ALB idle timeout was shorter than the slowest catalog query" is a commit.

### Review and CI

Every pull request runs the app pipeline (ruff, pytest, image build and Trivy scan),
manifest validation (`kustomize` render, `kubeconform -strict`, `conftest`) and
`terraform fmt`/`validate`. A plan is posted as a comment when AWS credentials are
available. Merges require a green run; nothing is merged on a red badge.

### Community

* **Questions and ideas:** open a discussion or an issue with the `question` label.
* **Bugs:** include the cloud, the command you ran, and the relevant log lines with any
  secret values redacted.
* **Security issues:** please **do not** open a public issue. Report privately through
  GitHub's *Security → Report a vulnerability* so a fix can ship before disclosure.
* **Code of conduct:** be decent. Harassment, dismissiveness and gatekeeping are not
  welcome here; maintainers may remove comments or contributions that make the project
  worse to participate in.
* **Credit:** contributors are listed in the release notes for the version that includes
  their change.

## Decisions

Architecture decisions live in [`docs/adr`](docs/adr):
[0001 one app, three clouds](docs/adr/0001-one-app-three-clouds.md) ·
[0002 no static credentials](docs/adr/0002-oidc-no-static-credentials.md) ·
[0003 gateway at the edge](docs/adr/0003-gateway-at-the-edge.md) ·
[0004 Kubernetes as a second runtime](docs/adr/0004-kubernetes-parity.md) ·
[0005 internal mutual TLS](docs/adr/0005-internal-mutual-tls.md) ·
[0006 cert-manager issues the internal PKI](docs/adr/0006-cert-manager-internal-pki.md).

## Notes

* Terraform ≥ 1.6 is required; OpenTofu works with the same HCL.
* The application is Python 3.12 / FastAPI. Swapping the language changes nothing below
  the container boundary — the infrastructure only knows an image and a port.
* MIT licensed — see [LICENSE](LICENSE).
