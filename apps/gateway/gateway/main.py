"""Gateway (BFF): the only internet-facing service.

Responsibilities kept deliberately narrow:
  1. verify the JWT for protected routes and forward the user id downstream;
  2. route /auth/* and /catalog/* to the owning service over private DNS;
  3. expose health endpoints the load balancer can poll.

Auth happens once at the edge; each downstream service still verifies the token
itself (defence in depth). See docs/adr/0003-gateway-at-the-edge.md.
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status

from common.config import load_settings
from common.observability import configure_logging, install_request_context
from common.security import TokenError, bearer_token, decode_token
from common.tls import client_ssl_context

from .proxy import forward, relay

__version__ = "1.0.0"
GIT_SHA = os.getenv("GIT_SHA", "dev")

settings = load_settings("gateway")
configure_logging(settings.service_name, settings.log_level)
log = logging.getLogger(__name__)

AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL", "http://localhost:8001")
CATALOG_SERVICE_URL = os.getenv("CATALOG_SERVICE_URL", "http://localhost:8002")

# Paths that must stay public: you cannot present a token before you have one.
PUBLIC_PREFIXES = ("/auth/register", "/auth/login", "/auth/refresh")


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Hold one pooled HTTP client for the process lifetime.

    With a CA configured the client verifies the upstream certificate and presents
    its own, so the hop to auth/catalog is mutual TLS. Without one (local, tests)
    the same client speaks plain HTTP -- no branch anywhere else in the gateway.
    """
    ssl_context = client_ssl_context()
    app.state.client = httpx.AsyncClient(
        timeout=httpx.Timeout(10.0, connect=3.0),
        limits=httpx.Limits(max_connections=100, max_keepalive_connections=20),
        verify=ssl_context if ssl_context is not None else True,
    )
    log.info(
        "gateway ready",
        extra={"auth_url": AUTH_SERVICE_URL, "catalog_url": CATALOG_SERVICE_URL},
    )
    yield
    await app.state.client.aclose()


app = FastAPI(
    title="Gateway",
    version=__version__,
    description="Single public entrypoint; validates JWTs and proxies to internal services.",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
install_request_context(app)


def authenticate(authorization: str | None = Header(default=None)) -> dict:
    """Validate the bearer token presented to the edge."""
    try:
        return decode_token(settings, bearer_token(authorization))
    except TokenError as exc:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


@app.get("/healthz", tags=["ops"])
def healthz() -> dict[str, str]:
    """Liveness probe: the gateway process itself."""
    return {
        "status": "ok",
        "service": settings.service_name,
        "version": __version__,
        "sha": GIT_SHA,
    }


@app.get("/readyz", tags=["ops"])
async def readyz(request: Request) -> dict[str, object]:
    """Readiness probe: report upstream reachability without failing the pod."""
    client: httpx.AsyncClient = request.app.state.client
    upstreams = {"auth": AUTH_SERVICE_URL, "catalog": CATALOG_SERVICE_URL}
    reachable: dict[str, str] = {}
    for name, url in upstreams.items():
        try:
            response = await client.get(f"{url.rstrip('/')}/healthz", timeout=2.0)
            reachable[name] = "up" if response.status_code == 200 else "degraded"
        except httpx.HTTPError:
            reachable[name] = "down"
    return {"status": "ready", "service": settings.service_name, "upstreams": reachable}


@app.get("/", tags=["ops"])
def index() -> dict[str, object]:
    """Small service index, handy when smoke-testing a fresh deployment."""
    return {
        "service": "gateway",
        "version": __version__,
        "sha": GIT_SHA,
        "routes": {
            "POST /auth/register": "create an account",
            "POST /auth/login": "obtain access + refresh tokens",
            "POST /auth/refresh": "rotate tokens",
            "GET /auth/me": "current user (token required)",
            "GET|POST /catalog/items": "list or create items (token required)",
            "GET|PUT|DELETE /catalog/items/{id}": "manage an item (token required)",
        },
    }


@app.api_route("/auth/{path:path}", methods=["GET", "POST"], tags=["auth"])
async def proxy_auth(path: str, request: Request) -> Response:
    """Forward auth traffic. The auth service enforces auth on its own routes."""
    response = await forward(request.app.state.client, request, AUTH_SERVICE_URL)
    return relay(response)


@app.api_route(
    "/catalog/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE"],
    tags=["catalog"],
)
async def proxy_catalog(
    path: str,
    request: Request,
    claims: dict = Depends(authenticate),
) -> Response:
    """Validate the JWT at the edge, then forward the user id to the catalog."""
    response = await forward(
        request.app.state.client,
        request,
        CATALOG_SERVICE_URL,
        extra_headers={"X-User-Id": claims["sub"]},
    )
    return relay(response)
