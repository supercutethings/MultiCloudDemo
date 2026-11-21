"""Password hashing and RS256 JWT issuing/verification.

Design notes:
  * scrypt from the standard library: no native build, no supply-chain surprise,
    and a memory-hard KDF instead of a raw SHA.
  * RS256 (asymmetric) so only the auth service holds the private key and every
    other service can verify tokens with the public key alone.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
from datetime import UTC, datetime, timedelta

import jwt

from common.config import Settings

SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_KEY_LEN = 32
MIN_PASSWORD_LENGTH = 12

JWT_ALGORITHM = "RS256"


class TokenError(Exception):
    """Raised when a token is missing, expired, tampered with, or of the wrong type."""


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def hash_password(password: str) -> str:
    """Hash a password with a random salt. Format: scrypt$N$r$p$salt$digest."""
    if len(password) < MIN_PASSWORD_LENGTH:
        raise ValueError(f"password must be at least {MIN_PASSWORD_LENGTH} characters")

    salt = os.urandom(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=SCRYPT_KEY_LEN,
    )
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${_b64encode(salt)}${_b64encode(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    """Constant-time verification against a hash produced by `hash_password`."""
    try:
        scheme, n, r, p, salt_b64, digest_b64 = encoded.split("$")
        if scheme != "scrypt":
            return False
        candidate = hashlib.scrypt(
            password.encode("utf-8"),
            salt=_b64decode(salt_b64),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(_b64decode(digest_b64)),
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(candidate, _b64decode(digest_b64))


def create_token(
    settings: Settings,
    subject: str,
    token_type: str = "access",
    extra_claims: dict | None = None,
) -> tuple[str, int]:
    """Sign a JWT for `subject`. Returns the token and its lifetime in seconds."""
    if not settings.jwt_private_key:
        raise TokenError("JWT_PRIVATE_KEY is not configured; cannot sign tokens")

    ttl = (
        settings.access_token_ttl_seconds
        if token_type == "access"
        else settings.refresh_token_ttl_seconds
    )
    now = datetime.now(UTC)
    claims = {
        "sub": subject,
        "type": token_type,
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=ttl)).timestamp()),
        "jti": base64.urlsafe_b64encode(os.urandom(9)).decode("ascii"),
    }
    claims.update(extra_claims or {})

    token = jwt.encode(claims, settings.jwt_private_key, algorithm=JWT_ALGORITHM)
    return token, ttl


def decode_token(settings: Settings, token: str, expected_type: str = "access") -> dict:
    """Verify signature, issuer, audience and expiry; assert the token type."""
    if not settings.jwt_public_key:
        raise TokenError("JWT_PUBLIC_KEY is not configured; cannot verify tokens")
    try:
        claims = jwt.decode(
            token,
            settings.jwt_public_key,
            algorithms=[JWT_ALGORITHM],
            audience=settings.jwt_audience,
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub", "aud", "iss", "type"]},
        )
    except jwt.PyJWTError as exc:  # expired, bad signature, wrong audience, ...
        raise TokenError(str(exc)) from exc

    if claims.get("type") != expected_type:
        raise TokenError(f"expected a {expected_type} token, got {claims.get('type')!r}")
    return claims


def bearer_token(authorization_header: str | None) -> str:
    """Pull the token out of an Authorization header, tolerating a missing scheme."""
    if not authorization_header:
        raise TokenError("missing Authorization header")
    parts = authorization_header.split()
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    if len(parts) == 1:
        return parts[0]
    raise TokenError("malformed Authorization header")
