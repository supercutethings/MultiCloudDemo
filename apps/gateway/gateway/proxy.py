"""Minimal reverse proxy used by the gateway to reach internal services."""

from __future__ import annotations

import logging

import httpx
from fastapi import HTTPException, Request, Response, status

log = logging.getLogger(__name__)

# Headers that must not be forwarded across a proxy hop (RFC 7230 section 6.1).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}


def _forwardable_headers(request: Request, extra: dict[str, str] | None = None) -> dict[str, str]:
    """Copy end-to-end request headers and drop hop-by-hop ones."""
    headers = {
        name: value for name, value in request.headers.items() if name.lower() not in HOP_BY_HOP
    }
    headers.update(extra or {})
    return headers


async def forward(
    client: httpx.AsyncClient,
    request: Request,
    upstream_base_url: str,
    extra_headers: dict[str, str] | None = None,
) -> httpx.Response:
    """Proxy the incoming request to `upstream_base_url`, preserving path and query."""
    target = f"{upstream_base_url.rstrip('/')}{request.url.path}"
    if request.url.query:
        target = f"{target}?{request.url.query}"

    try:
        upstream_response = await client.request(
            method=request.method,
            url=target,
            headers=_forwardable_headers(request, extra_headers),
            content=await request.body(),
        )
    except httpx.TimeoutException as exc:
        log.warning("upstream timeout: %s %s", request.method, target)
        raise HTTPException(status.HTTP_504_GATEWAY_TIMEOUT, "upstream timeout") from exc
    except httpx.HTTPError as exc:
        log.warning("upstream unreachable: %s %s (%s)", request.method, target, exc)
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "upstream unavailable") from exc

    return upstream_response


def relay(upstream_response: httpx.Response) -> Response:
    """Pass an upstream response back to the client unchanged (status, body, type).

    Returns a Starlette response, not the httpx one: FastAPI would otherwise try to
    serialise the httpx object as JSON.
    """
    return Response(
        status_code=upstream_response.status_code,
        content=upstream_response.content,
        headers={
            name: value
            for name, value in upstream_response.headers.items()
            if name.lower() not in HOP_BY_HOP
        },
    )
