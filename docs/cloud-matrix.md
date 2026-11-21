# Cloud matrix

Status: **all four serverless legs and all three Kubernetes legs are implemented.** The
serverless legs are ECS (AWS), Container Apps (Azure) and Cloud Run (GCP); the Kubernetes
legs are EKS, AKS and GKE. Nothing here claims to work before it does: a row is ✅ when the
code exists *and* something runs it, and anything less is marked 🚧 or ⚠️.

| Capability | AWS | Azure | GCP |
|---|---|---|---|
| Public entrypoint | ✅ ALB, single target group | ✅ Container Apps ingress | ✅ Cloud Run URL (no LB) |
| TLS termination | ✅ HTTPS listener + ACM (optional in dev) | ✅ Platform-managed certificate on the environment domain | ✅ Google-managed certificate on `*.run.app` |
| Compute | ✅ ECS Fargate | ✅ Container Apps (consumption) | ✅ Cloud Run (gen2) |
| Replica scaling | ✅ Target tracking on CPU | ✅ HTTP + CPU rules, 0 → 10 | ✅ Concurrency + request-based, 0 → 10 |
| Service discovery | ✅ Cloud Map private DNS | ✅ Internal ingress FQDN | ✅ Internal-only service URI via VPC connector |
| Database | ✅ RDS PostgreSQL, private | ✅ Flexible Server, delegated subnet, no public endpoint | ✅ Cloud SQL, private IP via VPC peering, no public IP |
| Secrets | ✅ Secrets Manager | ✅ Key Vault, one secret per value, RBAC | ✅ Secret Manager, one secret per value, per-service accessor |
| Workload identity | ✅ One IAM role per service | ✅ One user-assigned identity per app | ✅ One service account per service |
| Registry | ✅ ECR, immutable tags | ✅ ACR, admin account disabled | ✅ Artifact Registry, cleanup policy, no `latest` |
| Logs | ✅ CloudWatch, JSON + request id | ✅ Log Analytics | ✅ Cloud Logging (structured stdout) |
| CI authentication | ✅ GitHub OIDC → IAM role | ✅ GitHub OIDC → Entra ID federated credential | ✅ Workload Identity Federation → service account (`infra/bootstrap/gcp`) |
| State | ✅ S3 + DynamoDB lock | ✅ Blob + lease (`backend.example.hcl`) | ✅ GCS bucket, prefix `gcp/cloudrun/dev` (no backend lock in Terraform 1.9) |
| Internal transport | ✅ Application-level mTLS on 8443 | ⚠️ HTTP inside the environment (ingress terminates TLS) | ⚠️ HTTP inside the VPC (Cloud Run terminates TLS) |
| Approx. monthly cost | ≈ $95 (or $0.26 for 2 h) | ≈ $0–68 (≈ $0 idle) | ≈ $13–32 (≈ $13 without the LB) |

## Kubernetes runtime (EKS / AKS / GKE)

The application layer is literally the same YAML in all three columns; only ingress, secret
store and cluster configuration differ. Details: [kubernetes.md](kubernetes.md).

| Capability | EKS | AKS | GKE |
|---|---|---|---|
| Cluster scope | regional (3 private subnets) | regional (3 zones) | **regional** control plane |
| Node pools across AZs | 3 AZs, managed node group | 1 pool, zones 1/2/3 | 3 zones, 1 node/zone min |
| Pod autoscaling | ✅ HPA v2 (3→24) | ✅ HPA v2 (3→24) | ✅ HPA v2 (3→24) |
| Node autoscaling | ✅ Cluster Autoscaler 3→12 | ✅ AKS autoscaler 3→12 | ✅ GKE autoscaler 1→4 per zone |
| Ingress | ✅ ALB via controller (IP targets) | ✅ Application Gateway (AGIC) | ✅ GCE Ingress + BackendConfig |
| Managed TLS | ✅ ACM (BYO cert ARN) | ✅ K8s TLS secret / cert-manager | ✅ ManagedCertificate |
| Secrets | ✅ Secrets Manager via ESO + IRSA | ✅ Key Vault via ESO + workload identity | ✅ Secret Manager via ESO + Workload Identity |
| Network policy | ✅ VPC CNI policy / NetworkPolicy | ✅ Calico | ✅ Dataplane V2 (eBPF) |
| Pod Security | ✅ PSA `restricted` | ✅ PSA + Azure Policy | ✅ PSA + Binary Authorization |
| Private API endpoint | ✅ option, CIDR-restricted | ✅ option, authorized ranges | ✅ option, master authorized networks |
| DB HA | RDS Multi-AZ | Flexible Server ZoneRedundant | Cloud SQL REGIONAL |
| DB transport | `rds.force_ssl=1` + `sslmode=require` | `require_secure_transport=ON` + `sslmode=require` | `ssl_mode=ENCRYPTED_ONLY` + `sslmode=require` |
| Internal mTLS | app-level, leaves issued by cert-manager in-cluster | same | same |
| Caller authorisation | per-identity client CA, allow-listed per service | same | same |
| Certificate rotation | cert-manager renews at 10 days out, Reloader rolls the pods | same | same |
| Certificate lifetime | 30-day leaves, 5-year CA | same | same |
| Approx. cost | ≈ $295/mo | ≈ $150/mo | ≈ $215/mo |

## Provider differences worth knowing

These are the things that actually cost time on a multicloud build. They belong in the
README of a senior portfolio, not hidden in commit messages.

**AWS**

* The ALB has a fixed hourly charge regardless of traffic; it is the single largest line
  item after the NAT gateway. This is why the AWS environment is ephemeral.
* IAM is per-resource here: one execution role for image pulls and secrets, one task role
  per service. Deleting a task definition does not delete its role — role hygiene is a
  manual step, and over time orphaned roles accumulate.
* Cloud Map with a *private DNS* namespace is the only option that gives plain
  `auth.<ns>.local` resolution from tasks; an HTTP namespace requires the ECS service
  connect agent and is easy to misconfigure.
* ECS service `wait_for_steady_state` is the difference between "apply succeeded" and
  "apply succeeded *and* the container is actually healthy". It is enabled.

**Azure**

* Container Apps ingress has no path-based routing rules (traffic splits across revisions,
  not paths). That is precisely why the gateway exists in this architecture: the routing
  layer is the application edge, not the platform edge.
* Managed certificates require a custom domain and a verification record; with the default
  `*.azurecontainerapps.io` domain you get HTTPS, but nothing to demonstrate about cert
  lifecycle management.
* `minReplicas: 0` is what makes the stack free when idle, and what makes the first request
  after a quiet period slow (~2–5 s). That trade-off is documented rather than discovered;
  `infra/envs/azure/dev` keeps one warm gateway replica and lets the internal services
  scale to zero.
* Internal ingress terminates TLS and forwards plaintext to the container, with no client
  certificate passthrough. So this leg keeps the *boundary* (only the gateway is public,
  the rest is reachable only inside the environment) but not the application-level mTLS
  that ECS and Kubernetes use — a real gap, recorded in the table above rather than
  papered over.
* A delegated subnet belongs to the service it is delegated to. The database and the app
  environment therefore cannot share one, which is why the VNet has three.
* The CI service principal needs **Contributor and User Access Administrator**: the modules
  create role assignments, and Contributor alone fails on the first one.

**GCP**

* Cloud Run has no address inside the VPC. Every call to the private database or to an
  internal-only service goes through a Serverless VPC Access connector — one extra resource,
  one extra network hop, and the step most "Cloud Run + Cloud SQL" tutorials skip. The
  connector is free; the egress is not.
* `INGRESS_TRAFFIC_INTERNAL_ONLY` means "from the VPC or from a Google load balancer", not
  "from anywhere in the project". It is enforced at the front end, before IAM: a public
  request gets a 404, not a 403, which is a confusing thing to debug if you expect IAM.
* `vpc_access.egress` defaults to `PRIVATE_RANGES_ONLY`, which does **not** cover Cloud SQL's
  private address. Both services set `ALL_TRAFFIC` for that reason.
* Cloud Run terminates TLS and forwards plaintext, exactly like Container Apps, so the
  internal hop here is HTTP inside the VPC rather than application-level mTLS. Same gap,
  same place in the table.
* Cloud SQL's private IP comes from a peering range allocated by
  `google_service_networking_connection`. Re-creating it after a partial destroy fails with
  "connection already exists" — the fix is to delete the peering, not to re-apply.
* Revision-based deploys mean there is no task definition to inspect; "what is running" is
  `gcloud run revisions list`, not `aws ecs describe-task-definition`.
* The global HTTPS load balancer is a separate paid product (~$18/month) and is not required
  for Cloud Run to work. It is not deployed here; `docs/cost.md` documents the trade.

**Kubernetes specifics**

* Only EKS needs a third-party node autoscaler (Helm + IRSA). AKS and GKE ship one, which
  is why `scripts/cluster-addons.sh` installs very different sets per cloud.
* Only GKE's load balancer is not a pod: health checks arrive from Google's published
  ranges, so the gateway NetworkPolicy needs `ipBlock` rules instead of a namespace
  selector. This is the single most commonly-missed detail when porting a manifest set.
* Azure Key Vault has no JSON property extraction, unlike Secrets Manager. The AWS overlay
  reads `private_key` out of one JSON secret; the Azure overlay reads three separate vault
  secrets. Same Kubernetes Secret keys either way, so the Deployments never change.
* EKS is the only one of the three where the control plane is a line item you can see
  growing when you leave a cluster up.
