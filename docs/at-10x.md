# What I would change at 10× traffic

This is not a benchmark. It is the analysis I would want before someone points a real
campaign at this stack: where it breaks, in what order, and what I would change first.

Every number below comes from this repository — the pool sizes in `apps/common/db.py`, the
concurrency limits in the Cloud Run and Container Apps modules, the instance classes in
`infra/envs` — not from a load test I did not run.

## What 10× means here

The baseline is the demo: three services, one PostgreSQL, a load test that ramps to 30
concurrent users (`scripts/loadtest.k6.js`, `scripts/loadtest.py`). 10× is roughly **300
concurrent users, 100–300 rps** on a read-heavy mix with 20–30% logins, in one region.

The order of work, if I had to do it in one sprint:

1. Paginate the catalog read path (a day, removes the largest single response).
2. Rate limit `/auth/*` at the edge (a day, and it must come *before* scaling auth).
3. Put a connection pooler in front of PostgreSQL (a day, removes the hard ceiling).
4. Align per-instance concurrency with the pool size (an hour, removes the latency cliff).
5. Publish a JWKS endpoint with `kid` (a week, turns rotation into a non-event).
6. Add traces and RED metrics (a week, or you scale the wrong service).
7. Only then consider a queue for writes.

## The ceiling is connections, not CPU

Every replica opens at most **10** database connections: `pool_size=5, max_overflow=5` in
`apps/common/db.py`. Multiply by replicas and compare with the tier limit:

| Leg | Replicas at 10× | Connections | Database limit | Verdict |
|---|---|---|---|---|
| ECS, `db.t4g.micro` | 10 auth + 10 catalog | 200 | ≈ 112 | refused |
| Container Apps, B1ms | 10 + 10 | 200 | 50 | refused at ~3 replicas per service |
| Cloud Run, `db-f1-micro` | 10 + 10 | 200 | ≈ 25 | **already refused at 3 replicas** |

The GCP leg is the instructive one: three replicas of `auth` and three of `catalog` — well
inside the configured `max_instances = 3` — ask for 60 connections from a tier that allows
about 25. The failure is not slow, it is `FATAL: sorry, too many clients already`, and it
arrives long before the CPU graphs move.

The fix is not a bigger database. It is a pooler, and each cloud has a managed one:

* **AWS** — RDS Proxy, which also survives instance replacement without dropping connections.
* **Azure** — Flexible Server has PgBouncer built in (`pgbouncer.enabled`), no extra resource.
* **GCP** — Cloud SQL Enterprise Plus managed pooling; the free option is a PgBouncer
  sidecar, which is what I would run on the demo tier.

With transaction pooling the per-replica `pool_size` can drop to 2–3, and 20 replicas then
need 40–60 server connections instead of 200. The caveat is real: transaction mode breaks
session-level state — prepared statements, advisory locks, `SET` that outlives a statement.
This app uses none of those in the request path, which is why the trade is available at all.

## The second wall: concurrency and pool size disagree by 4×

`max_instance_request_concurrency = 40` on Cloud Run, against 10 connections per instance.
Thirty of those forty in-flight requests will queue on the pool. On ECS the same mismatch
appears differently: the endpoints are `def`, not `async def`, so FastAPI runs them on
AnyIO's 40-thread pool, and 40 threads share 10 connections.

This is the shape of failure that misleads people: **p95 latency climbs while CPU sits at
15%**. If you only look at CPU-based autoscaling — which is exactly what
`infra/modules/aws/service/main.tf` configures — nothing scales, because nothing looks busy.

Two ways out, and I would take both: set concurrency close to the pool size (or the pool
close to concurrency), and add latency-based scaling on top of CPU. A pooler alone hides the
symptom; it does not make 40 concurrent requests cheap.

## Login is the CPU path, and it is also the attack surface

`scrypt` at `N=2^14, r=8` costs about 16 MiB and tens of milliseconds per hash. At 10× that
is tens of logins per second of deliberate CPU work, which makes `auth` the first service to
need more replicas — not `catalog`. On Cloud Run the `cpu_idle = true` setting is fine here,
because the work happens inside the request, but it does mean an idle auth service gets no
CPU budget at all until the request arrives.

The uncomfortable part: **there is no rate limiting anywhere.** The gateway verifies JWTs on
`/catalog/*` and forwards `/auth/*` untouched, so `POST /auth/login` is an unauthenticated,
CPU-expensive endpoint with no per-IP or per-account limit. Scaling auth before adding a
limit makes credential stuffing cheaper for the attacker, not harder. Per-IP token bucket at
the edge, per-account exponential backoff in auth, and a lockout that is not a denial-of-
service weapon against a known email.

## The catalog read path has no upper bound

`list_items` selects every item owned by the caller, ordered by `created_at desc`, with no
`LIMIT`. At 10× the users with large collections get large responses: memory, JSON
serialisation and transfer all scale with the data, not with the request rate. This is the
cheapest high-value change in the list — cursor pagination (`?after=<created_at,id>&limit=50`)
and an index on `(owner_id, created_at desc)`.

The same argument applies to `GET /catalog/items/{id}` only if it grows joins. Today it does
not, and I would leave it alone.

## The gateway is one process with a fixed upstream pool

One `httpx.AsyncClient` per gateway process: `max_connections=100`,
`max_keepalive_connections=20`, 10 s timeout, 3 s connect. At 10× with N gateway replicas the
upstream concurrency is N × 100, and `auth`/`catalog` must accept it — which they cannot,
per the connection math above, unless the pooler is in place.

On ECS the upstream hop is mutual TLS, so every *new* connection pays a handshake. The
`handshake` scenario in `scripts/loadtest.py` measures exactly this, and it is the number
that decides whether raising `max_keepalive_connections` is worth it. On Azure and GCP the
hop is plaintext inside the platform, so keep-alive is cheaper but the per-replica pool is
still the throughput cap.

## Writes: not yet, but know where the seam is

Writes are single-row commits, synchronous, straight through. At 10× with bursty writes, the
seam is a queue between gateway and catalog for `POST`/`PUT`/`DELETE`, with an idempotency
key so a retry does not duplicate an item. I would not build it before the write rate
justifies it: it costs read-your-writes, and the UI here is a list that refreshes.

## JWT rotation becomes a coordination problem

One key pair, no `kid`, no JWKS — so rotation is a forced re-login for up to
`ACCESS_TOKEN_TTL_SECONDS` (900 s), as [jwt-rotation.md](jwt-rotation.md) says plainly. At
10× with more clients and more services, that is a visible event rather than a footnote. The
fix is the standard one: `kid` in the header, a `/.well-known/jwks.json` that publishes both
keys during the overlap, sign with the new key, drop the old one after two TTLs.

## What I would deliberately not change

* **Kubernetes.** The control plane buys rolling deploys, health checks and autoscaling that
  the serverless legs already have. At 10× it buys a node bill and a second operational
  surface. The Kubernetes leg exists to show it can be done, not because this traffic needs it.
* **Multi-region.** With one primary database, active-active is a consistency story pretending
  to be a latency story. The honest next step is a read replica in a second region for the
  catalog read path, not a second write region.
* **Sharding.** No tenant is large enough to justify the routing layer, and every shard key
  choice made now is wrong later.
* **A service mesh.** Three services, one hop. Application-level mTLS already covers ECS and
  Kubernetes; a mesh would add a data plane to solve a problem that does not exist yet.

## Cost at 10×

Back-of-envelope, and labelled as such: request-driven compute scales roughly linearly, the
fixed floor (load balancer, NAT, database) jumps one or two size classes rather than ten
times, so the bill lands around **6–8×** the numbers in [cost.md](cost.md) — roughly $600–700
on AWS, $400 on Azure, $220 on GCP — with two changes in character:

* **AWS stops being ephemeral.** At $95 the answer was "apply, screenshot, destroy". At 10×
  the NAT gateway and ALB are no longer the dominant line items, so Spot for the stateless
  services and RDS Proxy become the levers, not the destroy button.
* **Per-GB charges appear.** NAT data processing, Cloud Run egress through the connector, and
  cross-AZ traffic between the ALB and tasks all scale with traffic in a way they do not at
  demo volume. These are the lines that surprise people, because they are invisible in the
  Terraform diff.

## How I would know I was right

Not by reading this document — by measuring:

* SLOs on p95 and error rate per route, not per service.
* The load test as a regression gate: `scripts/loadtest.k6.js` already fails a run on
  thresholds, so wire it to a scheduled job against the ephemeral environment.
* Traces before scaling. Today the stack has request-id logs and nothing else, so "which hop
  is slow" is unanswerable — and that is exactly the question at 10×. OpenTelemetry traces
  plus a RED dashboard come before the queue, the pooler, and any instance-class change.

## What is not measured here

No production traffic exists, so nothing in this document is a measurement of load. The
connection limits quoted are the *smallest* tier of each provider, which is what the demo
deploys; the k6 thresholds are calibrated to a local run, not to a bill. Treat the ordering
as the claim — the first three items are arithmetic, not opinion — and the cost section as
an estimate.
