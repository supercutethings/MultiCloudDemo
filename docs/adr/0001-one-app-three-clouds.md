# ADR 0001 — One application, three providers

* Status: accepted
* Date: 2026-11-21

## Context

A multicloud portfolio can be assembled two ways: three unrelated demos, or one system
implemented three times. The first is quick to build and proves nothing; the second makes
the provider comparison meaningful because every difference in cost, latency, IAM model
and operational surface has a single cause — the provider.

## Decision

One reference platform (gateway + auth + catalog + PostgreSQL) is deployed to AWS, Azure
and GCP. Provider modules implement a shared contract (`infra/contracts/README.md`). The
application code is identical across clouds; only configuration differs, injected through
environment variables and the provider's secret manager.

Where a provider cannot express something (for example, no ALB-equivalent routing on
Container Apps), the module returns the closest native equivalent and the gap is recorded
in `docs/cloud-matrix.md`.

## Consequences

* The README can show a single architecture diagram and one smoke test that works
  everywhere: `scripts/smoke.sh`.
* Cross-cloud drift is a real risk, so the contract is asserted by tests rather than by
  discipline (Phase 4: `terraform test` per module).
* Each provider root is deployed independently; one cloud failing never blocks another.
* Cost comparison becomes honest, because the workload is constant.
