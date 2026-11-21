# ADR 0003 — One public service: the gateway

* Status: accepted
* Date: 2026-11-21

## Context

The obvious layout is to put all three services behind the load balancer with path rules
(`/auth/*`, `/catalog/*`). It is simple and it demonstrates LB routing, but it publishes
the auth service directly to the internet and makes every service responsible for its own
edge concerns (TLS, CORS, rate limiting, request ids).

## Decision

Only the **gateway** is internet-facing. The ALB has a single target group pointing at the
gateway; the gateway validates the JWT for protected routes, adds `X-Request-ID`, and
forwards to `auth` and `catalog` over private DNS (Cloud Map in AWS, internal DNS on the
other providers).

Downstream services still verify the token themselves. The gateway is not a trust
boundary — it is a convenience and a choke point. Defence in depth matters when someone
later adds a second path to a service.

## Consequences

* One hop of extra latency (~1 ms inside the VPC) in exchange for a single place to
  enforce authentication, logging and rate limiting.
* Only one target group, one security group ingress rule and one certificate to manage.
* Unauthenticated traffic never reaches a service that can write to the database.
* Path-based ALB routing is no longer demonstrated; it can be added for a staging
  variant without changing the service contract.
* Trade-off recorded deliberately: the gateway is a single point of failure for the
  platform, mitigated by running at least two tasks in staging and prod.
