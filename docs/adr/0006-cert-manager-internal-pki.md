# 0006 — cert-manager owns internal certificates on Kubernetes

**Status:** accepted · **Date:** 2026-11 · **Amends:** [0005](0005-internal-mutual-tls.md)

## Context

[ADR 0005](0005-internal-mutual-tls.md) put mutual TLS in the application and issued the
certificates from `infra/modules/pki`. That was the right layer and the right shape, with
one acknowledged weakness: **rotation was a manual `terraform apply -replace`**. A 90-day
leaf that nobody remembers to rotate is, on day 91, an outage — and in a repository meant to
show how a platform is *operated*, "we wrote a runbook" is weaker than "the cluster rotates
it and someone is paged if that stops working".

The same review surfaced two more questions that the single-CA design could not answer:

* **Who is allowed to call this service?** With one CA, any certificate it signed is
  accepted by every service. Adding a second internal caller silently granted it access to
  everything, which is the opposite of least privilege.
* **Does the renewed certificate actually reach the process?** A Secret updated on disk is
  invisible to a Python process that loaded its key at startup. This is the failure mode
  where the cluster reports every `Certificate` as `Ready` while the pod serves something
  that expires tonight.

## Decision

On Kubernetes, **cert-manager issues and rotates every internal certificate**, and the
trust relationships are modelled as two independent trust domains.

**Issuance.** A `selfSigned` issuer signs two CA `Certificate`s once (5 years, key rotation
`Never`), and two namespaced `Issuer`s sign the leaves (30 days, `renewBefore: 240h`,
`rotationPolicy: Always`). A component (`k8s/components/internal-pki`) is included by all
three overlays, so EKS, AKS and GKE run the identical objects. Terraform no longer creates
a PKI or a `pki` secret in the cluster environments; `infra/modules/pki` remains for ECS,
where there is no cert-manager.

**Identity.** There is no single CA. The **server CA** signs what auth and catalog present;
**one client CA per caller identity** signs what a caller presents. auth and catalog mount a
projected volume containing only the CAs they allow (`/tls/clients`), and
`common.tls` builds the verification bundle from those files. The gateway mounts the server
CA as its upstream trust anchor. A certificate from the wrong side of that split fails the
handshake, and that is the point.

**Delivery.** Reloader watches the Secret and rolls the Deployment, so a renewal reaches the
process; a policy rule fails CI if a Deployment mounts a Secret volume without it. Alerts
(`k8s/monitoring/certificates.yaml`) fire at 21 days and 7 days before expiry and whenever a
`Certificate` is not `Ready`, and `scripts/cert-expiry.sh` covers the no-Prometheus case.

## Why not check the certificate's subject in the application?

Because it cannot: uvicorn 0.32.1 never passes the peer certificate to the ASGI scope
(verified against the installed package: no `getpeercert`, no TLS extension, and the scope
is built without the transport). A middleware cannot see the caller's identity at all, so
in-process subject matching would mean parsing a header — which the caller itself controls.

Binding each identity to its own issuing CA moves the decision back to the handshake, where
it is unspoofable, and gives a stronger property than a CN check would have: a caller cannot
be renamed into someone else's identity, and revoking one service is dropping one CA from
one bundle.

## Consequences

* **Positive:** rotation is automatic (renew at 10 days out, new private key every time) and
  verifiable — `kubectl -n showcase get certificate` plus the expiry alerts.
* **Positive:** adding an internal caller is an explicit, reviewable change (its CA in the
  servers' projected volume and its namespace in the NetworkPolicy), rather than a side
  effect of certificate issuance.
* **Positive:** no CA key in Terraform state for the cluster environments; the ECS path
  keeps the Terraform module because it has no in-cluster issuer.
* **Negative:** one more controller (cert-manager) plus Reloader, and the CA private key now
  lives in a Kubernetes Secret in the application namespace. A real production estate would
  use a Vault issuer or ACM PCA and keep the key in an HSM; the component is swappable
  because the Deployments only know the three Secret names.
* **Negative:** rotation is still an *event* for the two CAs (5 years). Rotating a CA
  invalidates every leaf it signed, so it is a planned rollout, deliberately not a timer.
* **Negative:** leaves are 30 days now, which means the reload path is exercised roughly
  monthly in a live cluster — good, but it makes Reloader load-bearing rather than optional.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep Terraform-issued certificates, add a rotation runbook | A runbook is not a mechanism; the 91st day is still an outage |
| One CA for servers and clients, check CN/SAN in FastAPI | Uvicorn does not expose the peer certificate; the only available "identity" would be a client-supplied header |
| Trust the single CA and rely on NetworkPolicy for caller authorisation | Loses defence in depth: one misapplied policy grants full access, and the certificate is no longer a second lock |
| Service mesh (Linkerd/Istio) for automatic identity | Automatic mTLS for every pod, but a control plane + trust anchor to rotate, and nothing on the ECS path where no mesh exists |
| ACM PCA / Key Vault CA / CAS for the CAs | Correct for a company, ~$400/month for a portfolio; documented in `docs/cost.md` |
