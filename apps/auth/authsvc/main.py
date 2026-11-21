"""Auth service: registration, login, refresh and identity lookup.

It is the only service that holds the JWT private key, so key exposure is
limited to one workload -- the reason tokens are RS256 and not HS256.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from common.config import load_settings
from common.db import get_session, init_db, wait_for_db
from common.observability import configure_logging, install_request_context
from common.ops import start_ops_listener, stop_ops_listener
from common.security import (
    TokenError,
    bearer_token,
    create_token,
    decode_token,
    hash_password,
    verify_password,
)

from .models import User
from .schemas import LoginRequest, RefreshRequest, RegisterRequest, TokenResponse, UserResponse

__version__ = "1.0.0"

settings = load_settings("auth")
configure_logging(settings.service_name, settings.log_level)
log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Prepare storage before the container reports ready to the load balancer."""
    init_db(settings.database_url)
    if settings.environment != "local":
        wait_for_db()
    # Probes cannot present a client certificate, so they get their own listener.
    ops = await start_ops_listener(settings.service_name)
    log.info("auth service ready", extra={"environment": settings.environment})
    yield
    await stop_ops_listener(ops)


app = FastAPI(
    title="Auth service",
    version=__version__,
    description="Issues RS256 JWTs for the showcase platform.",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
install_request_context(app)


def _issue_tokens(user: User) -> TokenResponse:
    """Sign an access token plus a refresh token for a user."""
    access_token, expires_in = create_token(settings, user.id, "access", {"email": user.email})
    refresh_token, _ = create_token(settings, user.id, "refresh")
    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=expires_in,
    )


@app.get("/healthz", tags=["ops"])
def healthz() -> dict[str, str]:
    """Liveness: the process is up. Never touches the database."""
    return {"status": "ok", "service": settings.service_name}


@app.get("/readyz", tags=["ops"])
def readyz(session: Session = Depends(get_session)) -> dict[str, str]:
    """Readiness: the process can serve traffic (database reachable)."""
    session.execute(select(1))
    return {"status": "ready", "service": settings.service_name}


@app.post(
    "/auth/register",
    status_code=status.HTTP_201_CREATED,
    response_model=UserResponse,
    tags=["auth"],
)
def register(payload: RegisterRequest, session: Session = Depends(get_session)) -> UserResponse:
    """Create an account. Passwords are stored as scrypt hashes, never in clear."""
    email = payload.email.strip().lower()
    user = User(email=email, password_hash=hash_password(payload.password))
    session.add(user)
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "email already registered") from None
    return UserResponse(id=user.id, email=user.email)


@app.post("/auth/login", response_model=TokenResponse, tags=["auth"])
def login(payload: LoginRequest, session: Session = Depends(get_session)) -> TokenResponse:
    """Exchange valid credentials for a token pair."""
    user = session.scalar(select(User).where(User.email == payload.email.strip().lower()))
    # Verify even when the user is missing so timing does not leak account existence.
    encoded = user.password_hash if user else hash_password("invalid-placeholder-password")
    if not verify_password(payload.password, encoded) or user is None:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "invalid email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return _issue_tokens(user)


@app.post("/auth/refresh", response_model=TokenResponse, tags=["auth"])
def refresh(payload: RefreshRequest, session: Session = Depends(get_session)) -> TokenResponse:
    """Trade a valid refresh token for a new pair (rotation on every use)."""
    try:
        claims = decode_token(settings, payload.refresh_token, expected_type="refresh")
    except TokenError as exc:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "invalid refresh token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    user = session.get(User, claims["sub"])
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user no longer exists")
    return _issue_tokens(user)


@app.get("/auth/me", response_model=UserResponse, tags=["auth"])
def me(
    session: Session = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> UserResponse:
    """Return the caller's profile. Verifies the token independently of the gateway."""
    try:
        claims = decode_token(settings, bearer_token(authorization))
    except TokenError as exc:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    user = session.get(User, claims["sub"])
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user no longer exists")
    return UserResponse(id=user.id, email=user.email)
