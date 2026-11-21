# What this costs (free tier, real bill, and cheaper alternatives)

**Prices are indicative, not quoted.** They are list prices for a mid-2026 EU/US region,
730 hours per month, on-demand, excluding tax. Cloud pricing changes and varies by region —
check the provider calculator before you deploy:

* AWS — <https://calculator.aws>
* Azure — <https://azure.microsoft.com/pricing/calculator/>
* GCP — <https://cloud.google.com/products/calculator>

Everything below assumes the full stack: **3 services + managed PostgreSQL + load balancer**.

## TL;DR

| | Always-on, 1 replica each | Idle-optimised | Genuine free tier for this stack | 2-hour demo session |
|---|---|---|---|---|
| **AWS** | ≈ $95 / month | ≈ $36 / month | **None** | ≈ $0.26 |
| **Azure** | ≈ $68 / month | ≈ $0–5 / month | **Yes**, first 12 months | ≈ $0.19 |
| **GCP** | ≈ $32 / month | ≈ $13 / month | $300 credit for 90 days | ≈ $0.09 |

The one-line conclusion: **AWS has no free tier that covers a load balancer, NAT gateway and
Fargate**, so this repository treats AWS as an ephemeral demo (`apply` → screenshot →
`destroy`). Azure is the cheapest cloud to leave running on a new subscription, and GCP is
the cheapest to leave running after the credit expires.

## AWS (implemented)

| Component | Size | ≈ $/month | Free tier | Cheaper alternative |
|---|---|---|---|---|
| Application Load Balancer | 1, ~1 LCU | 18.00 | none | none — it *is* the demo |
| NAT Gateway | 1, single AZ | 32.85 | none | NAT instance `t4g.nano` ≈ $3.50 (slower, you patch it) |
| ECS Fargate | 3 × 0.25 vCPU / 0.5 GiB | 27.00 | none | **Fargate Spot ≈ $8** (−70%) |
| RDS PostgreSQL | `db.t4g.micro`, 20 GiB gp3, single-AZ | 14.50 | 750 h for 12 months on legacy accounts only | stop the instance between demos → storage only ≈ $2.30 |
| Secrets Manager | 2 secrets | 0.80 | none | SSM Parameter Store `SecureString` → free |
| ECR | 3 repos, < 1 GiB | 0.10 | 500 MiB | delete old images (lifecycle policy does this) |
| CloudWatch Logs | ~2 GiB, 7-day retention | 0.50 | 5 GiB / month | retention is already 7 days |
| Data transfer out | < 10 GiB | 0.30 | 100 GiB / month | — |
| **Total** | | **≈ $95** | | **≈ $36** (Spot + DB stopped + 0 tasks) |

Why the NAT gateway is not optional: private tasks need egress to pull images from ECR. The
"VPC endpoints instead" alternative sounds cheaper and is not — 3 interface endpoints × 2 AZs
is ≈ $44/month, more than a single NAT.

### AWS free tier in practice

Since 2025 new accounts get a **credits-based free plan** (a few hundred dollars valid for
about six months) rather than the old 12-month always-free list. The classic 12-month
free tier still exists for older accounts, and even then it does **not** include ALB, NAT
Gateway or Fargate. Treat AWS here as "credit-funded", and check what your account has
before assuming.

## Kubernetes (EKS / AKS / GKE)

The Kubernetes path costs **2–3× the serverless path** for the identical three services.
That is not a mistake in the Terraform; it is the price of a control plane, a minimum node
count, and (on AWS) one NAT gateway per AZ.

| Component | EKS | AKS | GKE (regional) |
|---|---|---|---|
| Control plane | $73 (standard) | $0 (Free tier) / $73 (Standard SLA) | $73 |
| Nodes, 3 AZ × 1 | $74 (3 × t4g.medium) | $90 (3 × B2s) | $74 (3 × e2-standard-2) |
| NAT / egress | $99 (one per AZ) | included | $2 (Cloud NAT) |
| Load balancer | $18 (ALB) | $20 (App Gateway v2) | $18 (GCLB) |
| PostgreSQL HA | $29 (Multi-AZ t4g.micro) | $36 (ZoneRedundant B1ms) | $50 (REGIONAL custom-1-3840) |
| Registry + secrets + logs | $2 | $5 (ACR Basic) | $1 |
| **Total, always-on** | **≈ $295** | **≈ $150** | **≈ $215** |
| **2-hour demo** | ≈ $0.80 | ≈ $0.41 | ≈ $0.59 |

Why the EKS number stings: three NAT gateways are $99/month on their own, more than the
control plane and the nodes combined. A single NAT would save $66 and reintroduce the AZ
single point of failure the exercise is about — `infra/envs/aws/eks` sets
`nat_gateway_per_az = true` and this document says what it costs. The ECS environment keeps
one NAT, because it is a demo.

Cheaper ways to run the Kubernetes path, in order of what they teach:

| Variant | Monthly | Trade-off |
|---|---|---|
| Single NAT, 2 AZs, no DB HA | ≈ $180 | The HA story disappears; still a working cluster |
| Spot node pool (tainted, in the Terraform) | −70% on nodes | Pods must tolerate `spot=true`; reclaim with 2 min notice |
| `terraform destroy` between demos | ≈ $0 | 15–20 minutes to rebuild; the apply is the demo |
| ACM Private CA instead of the free issuers | **+$400/mo** | The managed product and the right answer at company scale; $400/month is a portfolio budget decision, so the `tls` provider (ECS) and cert-manager (Kubernetes, $0) issue the same hierarchy |
| kube-prometheus-stack for the certificate alerts | **+$25–40/mo** | ~1 vCPU and 2–3 GiB of Prometheus plus Grafana. Off by default; `scripts/cert-expiry.sh --kube` needs only kubectl |
| cert-manager + Reloader | **$0** | Open source, per-cluster, no per-certificate charge — which is the whole reason they replace a managed CA here |
| GKE Autopilot | ≈ $120 | Per-pod billing, no node management, less to show |
| kind / k3d locally | $0 | Proves the manifests, proves nothing about IAM or AZs |

## Azure (implemented)

| Component | Size | ≈ $/month | Free tier | Cheaper alternative |
|---|---|---|---|---|
| Container Apps | 3 × 0.25 vCPU / 0.5 GiB | 0 idle / ≈ 50 always-on | 180k vCPU-s + 360k GiB-s per month | set `minReplicas: 0` → pay only per request |
| PostgreSQL Flexible Server | Burstable B1ms, 32 GiB | ≈ 18.00 | **750 h + 32 GiB free for 12 months** (new subscriptions) | stop the server (max 7 days at a time) |
| Container registry | ACR Basic | 5.00 | none | GHCR / Docker Hub (free for public images) |
| Key Vault | < 10k operations | 0.10 | none | — |
| Managed certificate + ingress | — | 0.00 | included | — |
| **Total** | | **≈ $68 always-on** | **≈ $0–5 in year one** | **≈ $0 idle** |

Azure is the only one of the three where the *whole* stack can sit inside free-tier limits
for a year: Container Apps scales to zero when nobody calls it, the ingress and managed
certificate are free, and a new subscription includes 750 hours of B1ms PostgreSQL.

## GCP (Phase 3)

| Component | Size | ≈ $/month | Free tier | Cheaper alternative |
|---|---|---|---|---|
| Cloud Run | 3 services, scale to zero | ≈ 0 idle | 2M requests + 180k vCPU-s per month | already the cheap option |
| Cloud SQL PostgreSQL | `db-f1-micro`, 10 GiB SSD | ≈ 13.00 | none (credit only) | none — the database is the floor |
| Global external HTTPS LB | 1 forwarding rule | ≈ 18.00 | none | **use the `*.run.app` URL → $0** (loses the LB demo) |
| Artifact Registry | < 1 GiB | 0.10 | 500 MiB | — |
| Secret Manager | 2 secrets | 0.15 | 6 active versions | — |
| **Total** | | **≈ $32 with LB / ≈ $13 without** | 90-day $300 credit | **≈ $13** |

Cloud Run's free tier is generous but it expires with the credit for the *database*, which
bills every hour regardless of traffic.

## Alternatives, ranked by what they actually teach you

| Option | What you get | Monthly cost | Trade-off |
|---|---|---|---|
| **1. Ephemeral full stack** (recommended) | Real ALB/Fargate/RDS; apply, record a GIF, destroy | AWS $0.26 per 2 h · Azure $0.19 · GCP $0.09 | Nothing runs between demos; state must be reproducible — which is the point of IaC |
| **1b. Ephemeral Kubernetes** | Real 3-AZ cluster, HPA scale-out, node autoscaling, ALB/GCLB/AppGW | AWS $0.80 per 2 h · AKS $0.41 · GKE $0.59 | 15–20 min to build; the load test is what you record |
| **2. Azure always-on, year one** | Full stack reachable 24/7 for screenshots and links | ≈ $0–5 | Cold starts with `minReplicas: 0`; free-tier clock runs out |
| **3. GCP always-on, no LB** | Full stack on `*.run.app` URLs | ≈ $13 | No load balancer to show; Cloud SQL still bills |
| **4. AWS with Spot + stopped RDS** | Practice the AWS reference architecture | ≈ $36 | NAT + ALB floor; stopping RDS is max 7 days |
| **5. Local only** (kind/k3d + Terraform + local Postgres) | Free, fast feedback loop | $0 | Proves nothing about cloud IAM, networking or billing |
| **6. LocalStack** | Terraform apply without an AWS account | $0 (community) | Incomplete service coverage; it will not validate ECS + ALB + RDS behaviour |
| **7. Single cloud, three environments** | dev/staging/prod promotion pipeline | Same as one cloud × env count | Loses the multicloud story, which is the CV hook |

A sensible portfolio budget: **~$5/month total** (Azure always-on in year one, everything
else ephemeral), plus ~$1 per demo session on AWS. That is cheaper than most people's
coffee, and it is what the repo is designed for.

## Cost controls already in this repository

Implemented, not aspirational:

* `make destroy` tears everything down, and the destroy path is tested each time the stack
  is created.
* `recovery_window_in_days = 0` on Secrets Manager, so deleted secrets free their names
  immediately instead of lingering for 30 days.
* Single NAT gateway, `az_count = 2`, `db.t4g.micro`, single-AZ RDS.
* CloudWatch retention 7 days; Container Insights off by default; ALB access logs off.
* ECR lifecycle policy keeps the last 10 images per repository; tags are immutable so the
  registry cannot silently grow duplicates.
* A monthly AWS Budgets alarm is created by `infra/bootstrap/aws` when you set
  `budget_alert_email` — the cheapest insurance against a forgotten `apply`.
* `deletion_protection = false` and `skip_final_snapshot = true` in dev only; both flip in
  `staging`/`prod` (see `infra/envs`).

## Deliberately not implemented (and why)

* **Fargate Spot** — a ~70% saving on compute, but a demo that gets interrupted mid-flight
  is worse than a demo that costs $19 more. It is a one-line change if you want it.
* **VPC endpoints instead of NAT** — more expensive at this scale, and the security gain
  over a NAT gateway is marginal when the security groups are already chained.
* **Savings Plans / reserved capacity** — nonsensical for an environment that lives for
  two hours.
