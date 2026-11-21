# 0004 — Kubernetes as a second runtime, not a replacement

**Status:** accepted · **Date:** 2026-11

## Context

`infra/envs/aws/dev` already runs the platform on ECS Fargate. Adding EKS, AKS and GKE
duplicates the operational surface: three more clusters, three ingress controllers, three
node-autoscaler integrations, three secret-store integrations, and a kustomize overlay per
cloud. A reasonable reader asks why.

Two honest answers:

1. **The job description says Kubernetes.** A senior DevOps portfolio that only shows ECS
   is answering a narrower question than the market asks.
2. **Kubernetes makes the provider differences sharper, not blurrier.** On ECS the
   comparison is "three serverless container services". On Kubernetes the application layer
   is *provably* identical (same manifests, same probes, same resource requests) and every
   remaining difference is attributable to the cluster, the ingress and the identity model.

## Decision

Keep both. The ECS path stays the cheapest way to run this stack on AWS. The Kubernetes
path is the portability and autoscaling demonstration.

Shared, provider-neutral:

* `k8s/base/` — namespace, service accounts, deployments, services, HPA, PDB, NetworkPolicy,
  quota. No cloud annotation appears here.
* The application contract: container port 8000, `/healthz`, `/readyz`, configuration from
  environment variables, secrets from files or env.

Provider-specific, one directory each:

* `k8s/overlays/<cloud>/` — ingress class and annotations, ClusterSecretStore +
  ExternalSecrets, database egress CIDR.
* `infra/modules/<cloud>/<cluster>/` — cluster, node pools, identity, add-on IRSA/federation.

## Consequences

* **Positive:** the "same app, three clouds" claim becomes demonstrable at the manifest
  level, not just the Terraform level. Autoscaling becomes visible (HPA + node autoscaler)
  instead of a single target-tracking policy.
* **Negative:** roughly 2× the operations to keep current. Kubernetes minor-version upgrades
  are now a recurring task for three clusters, and the add-on set (ESO, autoscaler, ingress)
  is a second thing to patch.
* **Negative:** cost. A three-AZ EKS cluster with per-AZ NAT, Multi-AZ RDS and an ALB is
  ~$250/month, against ~$95 for the ECS stack. The k8s environments are therefore the
  *ephemeral* ones — apply, record, destroy.
* **Mitigation:** `docs/kubernetes.md` is the runbook, `k8s-validate.yml` renders and
  policy-checks all three overlays on every pull request, so the three clouds cannot drift
  silently without a red build.

## Alternatives considered

| Option | Why not |
|---|---|
| Kubernetes only, drop ECS | Loses the "serverless is cheaper when you have no cluster team" argument, which is the more common real-world decision |
| One cloud's Kubernetes only | Weakens exactly the comparison the repository exists to make |
| Managed service mesh from day one | Adds a large dependency before there is a problem it solves; NetworkPolicy covers segmentation |
