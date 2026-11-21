"""Authentication dependency for the catalog service."""

from __future__ import annotations

from fastapi import Header, HTTPException, status

from common.config import Settings
from common.security import TokenError, bearer_token, decode_token


def require_user(settings: Settings):
    """Return a dependency that yields the caller's user id from a verified JWT.

    The gateway already validates the token, but the service verifies it again.
    Defence in depth: if the service is ever reachable from another path (service
    mesh, internal caller, misconfigured security group) the data stays protected.
    """

    def dependency(authorization: str | None = Header(default=None)) -> str:
        try:
            claims = decode_token(settings, bearer_token(authorization))
        except TokenError as exc:
            raise HTTPException(
                status.HTTP_401_UNAUTHORIZED,
                "invalid or expired token",
                headers={"WWW-Authenticate": "Bearer"},
            ) from exc
        return claims["sub"]

    return dependency
