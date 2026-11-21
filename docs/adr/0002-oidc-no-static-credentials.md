# ADR 0002 — No long-lived cloud credentials in CI

* Status: accepted
* Date: 2026-11-21

## Context

The usual shortcut is an IAM user with an access key stored as `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` GitHub secrets. Keys are long-lived, invisible until they leak,
and rotate only when someone remembers. Almost every public "Terraform + GitHub Actions"
tutorial does this.

## Decision

CI authenticates with **OpenID Connect federation**:

* AWS — `aws_iam_openid_connect_provider` trusts `token.actions.githubusercontent.com`,
  and the role's trust policy is pinned to `repo:<org>/<repo>` with the `pull_request`,
  `refs/heads/main` and `environment:*` subjects only (see `infra/bootstrap/aws`).
* Azure (planned) — federated credential on an app registration.
* GCP (planned) — Workload Identity Federation pool.

Workflow permissions are `id-token: write` and `contents: read`, nothing more.

## Consequences

* A compromised repository cannot exfiltrate a key that does not exist; the token is
  valid for minutes and scoped to one workflow run.
* `terraform apply` runs behind a GitHub Environment (`aws-dev`) with required reviewers,
  so a merge to `main` proposes a deployment rather than performing one silently.
* The role is deliberately split: `PowerUserAccess` for the data plane plus a narrow
  inline policy for creating only `${project}-*` roles. IAM is the one place a demo
  usually over-grants, and it is also the one place that can escalate privileges.
* Bootstrapping requires a human with admin rights exactly once (`infra/bootstrap/aws`),
  which is the accepted cost of not storing a bootstrap key in CI.
