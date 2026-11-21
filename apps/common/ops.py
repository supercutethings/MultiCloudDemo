"""Plaintext operations listener: liveness/readiness only, on its own port.

The data listener requires a client certificate, and neither the kubelet nor a
cloud load balancer can present one. Rather than weaken the data plane, each
internal service runs a second, tiny listener that answers exactly two paths and
touches no business data:

    OPS_PORT=8000  GET /healthz   process is alive (never touches the database)
                   GET /readyz    database reachable, 503 when it is not

That is the whole surface. Anything else on this port is a 404, and the port
carries no tokens, no catalog data and no passwords -- which is why it can be
open to the node network while 8443 stays gateway-only.

The listener is started inside the application's lifespan, so it shares the
process, the event loop and the graceful-shutdown deadline with the data
listener. It is disabled when OPS_PORT is unset (tests, plain uvicorn runs).
"""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import uvicorn
from fastapi import FastAPI, Response, status

from common import db

log = logging.getLogger(__name__)

_START_TIMEOUT_SECONDS = 5.0


def make_ops_app(service_name: str) -> FastAPI:
    """Build the two-route health application for one service."""
    app = FastAPI(
        title=f"{service_name} ops",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        """Liveness: the process is up. Deliberately does not touch the database."""
        return {"status": "ok", "service": service_name}

    @app.get("/readyz")
    def readyz(response: Response) -> dict[str, str]:
        """Readiness: the process can serve traffic, i.e. the database answers."""
        try:
            db.ping()
        except Exception as exc:  # noqa: BLE001 - any driver error means "not ready"
            log.warning("readiness check failed: %s", exc)
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            return {"status": "not-ready", "service": service_name}
        return {"status": "ready", "service": service_name}

    return app


class _QuietServer(uvicorn.Server):
    """uvicorn server that does not steal the process signal handlers.

    The data listener owns SIGTERM. If the ops server installed its own handlers it
    would intercept shutdown and the pod would be killed at the grace period.
    `capture_signals` is a context manager in uvicorn, so the override must yield.
    """

    @contextmanager
    def capture_signals(self) -> Iterator[None]:  # pragma: no cover - trivial override
        yield


@dataclass
class OpsListener:
    """Handle returned by `start_ops_listener`, consumed by `stop_ops_listener`."""

    server: uvicorn.Server
    task: asyncio.Task[None]


async def start_ops_listener(service_name: str) -> OpsListener | None:
    """Start the ops listener if OPS_PORT is set; return the server or None."""
    raw_port = os.getenv("OPS_PORT")
    if not raw_port:
        return None

    port = int(raw_port)
    server = _QuietServer(
        uvicorn.Config(
            make_ops_app(service_name),
            host="0.0.0.0",  # noqa: S104 - the kubelet/ALB probe reaches the pod IP
            port=port,
            log_config=None,
            access_log=False,
        )
    )
    task = asyncio.create_task(server.serve(), name=f"{service_name}-ops-listener")

    deadline = asyncio.get_running_loop().time() + _START_TIMEOUT_SECONDS
    while not server.started:
        if task.done():  # startup error (port in use, permissions); surface it
            task.result()
        if asyncio.get_running_loop().time() > deadline:
            server.should_exit = True
            raise RuntimeError(f"ops listener for {service_name} did not start on :{port}")
        await asyncio.sleep(0.02)

    log.info("ops listener started on :%s (healthz/readyz only)", port)
    return OpsListener(server=server, task=task)


async def stop_ops_listener(listener: OpsListener | None) -> None:
    """Ask the ops listener to stop and wait for it to finish."""
    if listener is None:
        return
    listener.server.should_exit = True
    await asyncio.gather(listener.task, return_exceptions=True)
