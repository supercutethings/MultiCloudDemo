"""Container entrypoint: run one service's data listener with optional mTLS.

`python -m common.serve authsvc.main:app` replaces a hard-coded uvicorn command
line so the TLS flags come from the environment instead of the Dockerfile. That
keeps one image working in three situations:

  * local / docker compose  -- no TLS variables, plain HTTP on PORT;
  * Kubernetes              -- certs mounted as files, mTLS on 8443;
  * ECS Fargate             -- certs injected as secret env vars, materialised to
                               files under /tmp before the listener starts.

TLS is never "optional at runtime if convenient": if a certificate is present but
the client CA is missing, `common.tls` logs a warning and the listener still
requires a client certificate when one is configured. Failures to load a bad
certificate abort start-up, which is what you want -- a service that silently
falls back to plaintext is worse than one that does not start.
"""

from __future__ import annotations

import importlib
import logging
import os
import sys

import uvicorn

from common import tls


def load_app(target: str):
    """Resolve an ASGI app from a 'module:attribute' string."""
    module_name, _, attribute = target.partition(":")
    if not module_name or not attribute:
        raise SystemExit(f"usage: python -m common.serve module:attribute (got {target!r})")
    return getattr(importlib.import_module(module_name), attribute)


def main(argv: list[str] | None = None) -> int:
    """Start the data listener and block until it exits."""
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print(__doc__)
        return 2

    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    app = load_app(args[0])

    port = int(os.getenv("PORT", "8000"))
    ssl_kwargs = tls.server_ssl_kwargs() or {}

    logging.getLogger(__name__).info(
        "starting %s on :%s (%s TLS)",
        args[0],
        port,
        "mutual" if ssl_kwargs.get("ssl_cert_reqs") else ("server" if ssl_kwargs else "no"),
    )

    uvicorn.run(
        app,
        host="0.0.0.0",  # noqa: S104 - the pod/container boundary is the network edge
        port=port,
        proxy_headers=True,
        forwarded_allow_ips=os.getenv("FORWARDED_ALLOW_IPS", "*"),
        **ssl_kwargs,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
