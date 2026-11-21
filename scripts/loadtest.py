#!/usr/bin/env python3
"""Load generator for the showcase gateway and the internal mTLS hop.

The point is to *show* the stack doing its job, not to invent a benchmark:

  * the `login` scenario is CPU-heavy on purpose (scrypt is memory-hard), so it drives the
    HorizontalPodAutoscaler on CPU within seconds;
  * the `catalog` scenario exercises the proxy -> catalog -> PostgreSQL path, which is
    I/O-bound and shows where replicas help less;
  * `mixed` sends 30% logins and 70% reads, which is roughly what a real client looks like;
  * `handshake` talks to an internal service's *data* port with a client certificate and
    separates the cost of the TLS handshake from the cost of the request -- the number
    that decides whether keep-alive is worth the complexity;
  * `rotate` swaps the client certificate mid-run and reports what that did to traffic,
    which is the question "can we rotate certificates without an outage?" answered with
    measurements instead of a shrug.

Run it against a port-forward, an ingress URL, or the local docker compose stack:

    python3 scripts/loadtest.py --url http://localhost:8080 --scenario login \\
        --concurrency 40 --duration 60

Measure the internal hop (local compose publishes auth's data port on 8001):

    python3 scripts/loadtest.py --url https://localhost:8001 --scenario handshake \\
        --ca-file .certs/server-ca.crt --cert-file .certs/gateway/tls.crt \\
        --key-file .certs/gateway/tls.key

Prove a rotation from an *unlisted* issuer is refused at the handshake:

    python3 scripts/loadtest.py --url https://localhost:8001 --scenario rotate \\
        --ca-file .certs/server-ca.crt --cert-file .certs/gateway/tls.crt \\
        --key-file .certs/gateway/tls.key --rotate-cert .certs/unlisted-client/tls.crt \\
        --rotate-key .certs/unlisted-client/tls.key --rotate-expect failure

Watch the scaling happen in another terminal:

    kubectl -n showcase get hpa,deploy,pods -w
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import ssl
import sys
import time
import uuid
from dataclasses import dataclass, field

import httpx


@dataclass
class TLSConfig:
    """Client-side TLS material. All optional: plain HTTP stays the default."""

    ca_file: str | None = None
    cert_file: str | None = None
    key_file: str | None = None
    skip_hostname_check: bool = False
    rotate_cert: str | None = None
    rotate_key: str | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.ca_file)


@dataclass
class Config:
    url: str
    scenario: str
    concurrency: int
    duration: float
    ramp: float
    email: str
    password: str
    path: str = "/healthz"
    tls: TLSConfig = field(default_factory=TLSConfig)
    token: str = ""


def percentile(samples: list[float], pct: float) -> float:
    """Nearest-rank percentile; good enough and dependency-free."""
    if not samples:
        return 0.0
    ordered = sorted(samples)
    rank = int(round((pct / 100.0) * (len(ordered) - 1)))
    return ordered[rank]


def ms(seconds: float) -> float:
    return round(seconds * 1000, 2)


def build_ssl_context(tls: TLSConfig) -> ssl.SSLContext | None:
    """Verify the server against the platform CA and present a client certificate.

    `--insecure-skip-hostname` keeps chain verification on and only disables the name
    check, which is occasionally needed when dialling a pod IP directly. It is never the
    default: hostname verification is what stops a valid certificate for another service
    being replayed.
    """
    if not tls.ca_file:
        return None

    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=tls.ca_file)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    if tls.skip_hostname_check:
        context.check_hostname = False
    if tls.cert_file and tls.key_file:
        context.load_cert_chain(tls.cert_file, tls.key_file)
    return context


async def prepare(client: httpx.AsyncClient, cfg: Config) -> None:
    """Create the test user (idempotent) and mint one token for the read scenario."""
    await client.post(
        f"{cfg.url}/auth/register",
        json={"email": cfg.email, "password": cfg.password},
    )
    login = await client.post(
        f"{cfg.url}/auth/login",
        json={"email": cfg.email, "password": cfg.password},
    )
    if login.status_code != 200:
        raise SystemExit(f"login failed with {login.status_code}: {login.text[:200]}")
    cfg.token = login.json()["access_token"]


async def worker(
    index: int,
    client: httpx.AsyncClient,
    cfg: Config,
    deadline: float,
    latencies: list[float],
    statuses: dict[int, int],
) -> None:
    """One virtual user: request, record, repeat until the deadline."""
    if cfg.ramp > 0:
        await asyncio.sleep(cfg.ramp * index / max(cfg.concurrency, 1))

    headers = {"Authorization": f"Bearer {cfg.token}"}
    while time.monotonic() < deadline:
        wants_login = cfg.scenario == "login" or (cfg.scenario == "mixed" and random.random() < 0.3)
        started = time.perf_counter()
        try:
            if wants_login:
                response = await client.post(
                    f"{cfg.url}/auth/login",
                    json={"email": cfg.email, "password": cfg.password},
                )
            else:
                response = await client.get(f"{cfg.url}/catalog/items", headers=headers)
            status = response.status_code
        except httpx.HTTPError:
            status = -1  # connection-level failure (timeout, reset, refused)

        latencies.append(time.perf_counter() - started)
        statuses[status] = statuses.get(status, 0) + 1


async def run(cfg: Config, context: ssl.SSLContext | None) -> dict[str, object]:
    limits = httpx.Limits(
        max_connections=cfg.concurrency + 10,
        max_keepalive_connections=cfg.concurrency + 10,
    )
    timeout = httpx.Timeout(15.0, connect=5.0)
    async with httpx.AsyncClient(
        limits=limits,
        timeout=timeout,
        verify=context if context is not None else True,
    ) as client:
        await prepare(client, cfg)
        await client.get(f"{cfg.url}/healthz")

        latencies: list[float] = []
        statuses: dict[int, int] = {}
        deadline = time.monotonic() + cfg.duration
        started = time.monotonic()

        await asyncio.gather(
            *(worker(i, client, cfg, deadline, latencies, statuses) for i in range(cfg.concurrency))
        )
        elapsed = time.monotonic() - started

    ok = statuses.get(200, 0)
    total = sum(statuses.values())
    errors = total - ok
    return {
        "scenario": cfg.scenario,
        "url": cfg.url,
        "concurrency": cfg.concurrency,
        "duration_s": round(elapsed, 2),
        "requests": total,
        "rps": round(total / elapsed, 1) if elapsed else 0.0,
        "ok": ok,
        "errors": errors,
        "error_rate": round(errors / total, 4) if total else 1.0,
        "statuses": {str(k): v for k, v in sorted(statuses.items())},
        "latency_ms": {
            "p50": ms(percentile(latencies, 50)),
            "p95": ms(percentile(latencies, 95)),
            "p99": ms(percentile(latencies, 99)),
            "max": ms(max(latencies) if latencies else 0),
        },
    }


async def _fresh_request(
    context: ssl.SSLContext | None, url: str, timeout: httpx.Timeout
) -> tuple[float, int]:
    """One request on a brand-new connection, so the TLS handshake is included.

    A new client per request with keep-alive pools of size zero is the only reliable way to
    force a full handshake through httpx; reusing a client would silently measure the
    request instead.
    """
    limits = httpx.Limits(max_connections=1, max_keepalive_connections=0)
    async with httpx.AsyncClient(
        verify=context if context is not None else True,
        timeout=timeout,
        limits=limits,
    ) as client:
        started = time.perf_counter()
        try:
            response = await client.get(url, headers={"Connection": "close"})
            status = response.status_code
        except httpx.HTTPError:
            status = -1
        return time.perf_counter() - started, status


async def _reused_request(client: httpx.AsyncClient, url: str) -> tuple[float, int]:
    """One request on an already-handshaked connection."""
    started = time.perf_counter()
    try:
        response = await client.get(url)
        status = response.status_code
    except httpx.HTTPError:
        status = -1
    return time.perf_counter() - started, status


async def _measure_reused(
    context: ssl.SSLContext | None, url: str, samples: int, timeout: httpx.Timeout
) -> list[float]:
    limits = httpx.Limits(max_connections=1, max_keepalive_connections=1)
    latencies: list[float] = []
    async with httpx.AsyncClient(
        verify=context if context is not None else True, timeout=timeout, limits=limits
    ) as client:
        await _reused_request(client, url)  # warm up: pay the handshake once, off the books
        for _ in range(samples):
            elapsed, _status = await _reused_request(client, url)
            latencies.append(elapsed)
    return latencies


async def run_handshake(cfg: Config, context: ssl.SSLContext | None) -> dict[str, object]:
    """Measure handshake cost on the internal data port, then rotate the certificate."""
    if context is None:
        raise SystemExit("--scenario handshake/rotate needs --ca-file (the server CA)")

    timeout = httpx.Timeout(15.0, connect=5.0)
    url = f"{cfg.url}{cfg.path}"
    samples = max(5, min(int(cfg.duration), 60))

    fresh: list[float] = []
    reused: list[float] = []
    statuses: dict[int, int] = {}
    rotation: dict[str, object] | None = None

    started = time.monotonic()
    for index in range(samples):
        # Rotation happens halfway through the sampling window so both halves are
        # comparable and the swap lands in the middle of live traffic.
        if (
            cfg.scenario == "rotate"
            and cfg.tls.rotate_cert
            and cfg.tls.rotate_key
            and index == samples // 2
        ):
            rotation = await _rotate(cfg, context, url, timeout, samples // 2, statuses, started)

        elapsed, status = await _fresh_request(context, url, timeout)
        fresh.append(elapsed)
        statuses[status] = statuses.get(status, 0) + 1

    reused = await _measure_reused(context, url, samples, timeout)
    elapsed_total = time.monotonic() - started

    ok = statuses.get(200, 0)
    total = sum(statuses.values())
    result: dict[str, object] = {
        "scenario": cfg.scenario,
        "url": cfg.url,
        "path": cfg.path,
        "duration_s": round(elapsed_total, 2),
        "requests": total,
        "ok": ok,
        "errors": total - ok,
        "error_rate": round((total - ok) / total, 4) if total else 1.0,
        "statuses": {str(k): v for k, v in sorted(statuses.items())},
        "tls": {
            "fresh_handshake_ms_p50": ms(percentile(fresh, 50)),
            "fresh_handshake_ms_p95": ms(percentile(fresh, 95)),
            "reused_connection_ms_p50": ms(percentile(reused, 50)),
            "reused_connection_ms_p95": ms(percentile(reused, 95)),
            "handshake_overhead_ms": round(
                ms(percentile(fresh, 50)) - ms(percentile(reused, 50)), 2
            ),
            "samples": len(fresh),
        },
    }
    if rotation is not None:
        result["rotation"] = rotation
    return result


async def _rotate(
    cfg: Config,
    context: ssl.SSLContext,
    url: str,
    timeout: httpx.Timeout,
    rounds: int,
    statuses: dict[int, int],
    run_started: float,
) -> dict[str, object]:
    """Swap the client certificate in place and see what the server does with it.

    `load_cert_chain` mutates the SSLContext the running client uses, so the next handshake
    presents the new certificate without restarting anything. That is the realistic
    rotation mechanism: the identity file changes, in-flight connections keep their old
    authentication, and only new handshakes are judged against the new material.

    A SWAP: expected outcome is that traffic continues. A swap to a certificate from an
    issuer the server does not allow must fail every subsequent handshake -- which is the
    allow rule doing its job, not a bug.
    """
    started = time.monotonic()
    context.load_cert_chain(cfg.tls.rotate_cert, cfg.tls.rotate_key)  # type: ignore[arg-type]

    ok_after = 0
    failed_after = 0
    recovered_after_ms: float | None = None

    for _ in range(rounds):
        _elapsed, status = await _fresh_request(context, url, timeout)
        statuses[status] = statuses.get(status, 0) + 1
        if status == 200:
            ok_after += 1
            if recovered_after_ms is None:
                recovered_after_ms = ms(time.monotonic() - started)
        else:
            failed_after += 1

    return {
        "at_s": round(started - run_started, 2),
        "certificate": cfg.tls.rotate_cert,
        "handshakes_after": rounds,
        "ok_after": ok_after,
        "failed_after": failed_after,
        "recovered_after_ms": recovered_after_ms,
    }


def describe(result: dict[str, object]) -> None:
    """Human-readable summary; the JSON mode exists for CI artefacts."""
    print(f"\n  scenario      {result['scenario']}")
    print(f"  target        {result['url']}{result.get('path', '')}")
    print(f"  duration      {result['duration_s']}s")
    print(f"  requests      {result['requests']}")
    print(f"  ok            {result['ok']}")
    print(f"  errors        {result['errors']} ({result['error_rate'] * 100:.2f}%)")
    print(f"  statuses      {result['statuses']}")

    tls_block = result.get("tls")
    if isinstance(tls_block, dict):
        print("\n  TLS")
        print(
            f"    handshake   p50 {tls_block['fresh_handshake_ms_p50']} ms / "
            f"p95 {tls_block['fresh_handshake_ms_p95']} ms"
        )
        print(
            f"    reused      p50 {tls_block['reused_connection_ms_p50']} ms / "
            f"p95 {tls_block['reused_connection_ms_p95']} ms"
        )
        print(
            f"    overhead    {tls_block['handshake_overhead_ms']} ms per new connection "
            f"({tls_block['samples']} samples)"
        )

    rotation = result.get("rotation")
    if isinstance(rotation, dict):
        print("\n  rotation")
        print(f"    certificate {rotation['certificate']}")
        print(f"    handshakes  {rotation['handshakes_after']} after the swap")
        print(f"    accepted    {rotation['ok_after']}   refused {rotation['failed_after']}")
        if rotation["recovered_after_ms"] is not None:
            print(f"    first 200   {rotation['recovered_after_ms']} ms after the swap")

    latency = result.get("latency_ms")
    if isinstance(latency, dict):
        print(f"  p50 / p95     {latency['p50']} ms / {latency['p95']} ms")
        print(f"  p99 / max     {latency['p99']} ms / {latency['max']} ms")
    print("\n  watch the scale-out:  kubectl -n showcase get hpa,deploy,pods -w\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--url", default="http://localhost:8080", help="base URL to drive")
    parser.add_argument(
        "--scenario",
        choices=["login", "catalog", "mixed", "handshake", "rotate"],
        default="login",
    )
    parser.add_argument("--path", default="/healthz", help="path for handshake/rotate")
    parser.add_argument("--concurrency", type=int, default=20)
    parser.add_argument("--duration", type=float, default=30.0, help="seconds of load")
    parser.add_argument("--ramp", type=float, default=5.0, help="seconds to reach full concurrency")
    parser.add_argument("--email", default=f"loadtest-{uuid.uuid4().hex[:8]}@example.com")
    parser.add_argument("--password", default="correct-horse-battery")
    parser.add_argument("--max-error-rate", type=float, default=0.05)

    tls_group = parser.add_argument_group("TLS / mutual TLS")
    tls_group.add_argument("--ca-file", help="CA that signed the server certificate")
    tls_group.add_argument("--cert-file", help="client certificate (mTLS)")
    tls_group.add_argument("--key-file", help="client private key (mTLS)")
    tls_group.add_argument(
        "--insecure-skip-hostname",
        action="store_true",
        help="verify the chain but not the hostname (dialling a pod IP directly)",
    )
    tls_group.add_argument("--rotate-cert", help="certificate to swap in mid-run")
    tls_group.add_argument("--rotate-key", help="key that goes with --rotate-cert")
    tls_group.add_argument(
        "--rotate-expect",
        choices=["success", "failure"],
        default="success",
        help="what the swap should do: keep serving, or be refused by the allow rule",
    )
    parser.add_argument("--json", action="store_true", help="print JSON only (for CI artifacts)")
    args = parser.parse_args()

    cfg = Config(
        url=args.url.rstrip("/"),
        scenario=args.scenario,
        concurrency=args.concurrency,
        duration=args.duration,
        ramp=args.ramp,
        email=args.email,
        password=args.password,
        path=args.path,
        tls=TLSConfig(
            ca_file=args.ca_file,
            cert_file=args.cert_file,
            key_file=args.key_file,
            skip_hostname_check=args.insecure_skip_hostname,
            rotate_cert=args.rotate_cert,
            rotate_key=args.rotate_key,
        ),
    )

    if cfg.scenario == "rotate" and not (cfg.tls.rotate_cert and cfg.tls.rotate_key):
        raise SystemExit("--scenario rotate needs --rotate-cert and --rotate-key")

    context = build_ssl_context(cfg.tls)

    if cfg.scenario in {"handshake", "rotate"}:
        result = asyncio.run(run_handshake(cfg, context))
    else:
        result = asyncio.run(run(cfg, context))

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        describe(result)

    rotation = result.get("rotation")
    if isinstance(rotation, dict):
        # A deliberate rotation has its own verdict: the handshakes *after* the swap decide
        # the outcome, so the global error rate must not turn an expected refusal into a
        # failure (and must not hide an unexpected one).
        ok_after = int(rotation["ok_after"])  # type: ignore[arg-type]
        failed_after = int(rotation["failed_after"])  # type: ignore[arg-type]
        served = ok_after > 0 and failed_after == 0
        refused = ok_after == 0 and failed_after > 0

        if args.rotate_expect == "success" and not served:
            raise SystemExit(
                f"rotation failed: {failed_after} of {ok_after + failed_after} handshakes "
                "after the swap were refused; expected the new certificate to be accepted"
            )
        if args.rotate_expect == "failure" and not refused:
            raise SystemExit(
                f"the allow rule did not hold: {ok_after} handshake(s) with the new "
                "certificate succeeded, expected every one to be refused"
            )
        return 0

    return 1 if result["error_rate"] > args.max_error_rate else 0


if __name__ == "__main__":
    sys.exit(main())
