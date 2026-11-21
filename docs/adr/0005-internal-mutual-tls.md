# 0005 — Mutual TLS at the application layer, not a service mesh

**Status:** accepted, amended by [0006](0006-cert-manager-internal-pki.md) · **Date:** 2026-11

## Context

The gateway talks to auth and catalog over private DNS. On ECS that is Cloud Map inside the
VPC, on Kubernetes it is a ClusterIP Service; in both cases the hop is plaintext HTTP. The
login request body carries a password, and the catalog hop carries a bearer token, so
anyone with read access to the network — a compromised pod, a mis-scoped security group, a
packet capture on a node — sees credentials. A senior review asks why not mTLS, and "we
trust the VPC" is not an answer.

The obvious alternatives were a service mesh (Linkerd or Istio ambient) or terminating TLS
at the ingress and calling it done. Ingress termination protects nothing here: the traffic
that needs protection *starts* behind the ingress.

## Decision

Mutual TLS **in the application process**, on a dedicated data port, for every internal hop:

* auth and catalog serve HTTPS on **8443** with `ssl_cert_reqs=CERT_REQUIRED` and a CA
  bundle, so a caller without a valid client certificate fails during the handshake,
  before routing, parsing or the database dependency.
* the gateway is the only holder of a **client** certificate (`clientAuth` EKU); it
  verifies the service certificate *and hostname* against the platform CA.
* probes and load balancers cannot present certificates, so each internal service also runs
  a plaintext **ops port on 8000** that answers `/healthz` and `/readyz` and nothing else.
* certificates come from one private CA per environment (`infra/modules/pki`), stored in
  the provider secret manager: Secrets Manager as one JSON document on AWS, one Key Vault
  secret per PEM on Azure, one Secret Manager secret per PEM on GCP.
* request-level authorisation is unchanged: the JWT is still the user identity. A
  certificate proves *which workload* is calling, not *who* the user is.

## Consequences

* **Positive:** the same guarantee on Compose, ECS, EKS, AKS and GKE with no mesh, no
  sidecar, no extra hop and no per-cloud networking product. Verified by a real handshake
  test (`apps/tests/test_mtls.py`) and `scripts/mtls-check.sh`.
* **Positive:** blast radius of a stolen secret is smaller — the CA key is never mounted
  into a workload, so a compromised pod cannot mint identities.
* **Negative:** two listeners per service, and a second port in every Deployment, Service
  and NetworkPolicy. This is the cost the ops port buys.
* **Negative:** on the ECS path, leaf rotation is still a `terraform apply -replace`
  operation. On Kubernetes that weakness is closed: [ADR 0006](0006-cert-manager-internal-pki.md)
  moves issuance to cert-manager, splits server and caller trust domains, and adds expiry
  alerts.
* **Negative:** the ops port is reachable by anything that can reach the pod network,
  because kubelet probes come from the node and no podSelector can match them. It carries
  no data, and the policy file says so explicitly.

## Alternatives considered

| Option | Why not |
|---|---|
| Linkerd / Istio ambient | Automatic mTLS for every pod, but three more control planes to run and a trust anchor to rotate; the app-level version still works on ECS, where no mesh exists |
| TLS terminated only at the ingress | Leaves the interesting hop (gateway → auth, with the password in the body) in plaintext |
| mTLS inside FastAPI middleware | Uvicorn 0.32 does not expose the peer certificate to the ASGI scope, so the app cannot verify it without a proxy |
| Self-signed per-service certificates | No common trust anchor means every client pins every server; rotation becomes N² work |
