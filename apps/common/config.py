"""Environment-driven configuration shared by every service.

Every value has a working local default so `make up` runs with no setup. In the
cloud the same names are injected by the container definition, which keeps the
difference between "laptop" and "prod" purely configuration.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _read_pem(env_name: str, path_env_name: str) -> str | None:
    """Read a PEM key from a file path if set, otherwise from a raw env var.

    File path wins because Kubernetes/ECS mount secrets as files. The env-var
    branch supports CI and tests, and unescapes `\\n` for one-line PEMs.
    """
    path = os.getenv(path_env_name)
    if path and Path(path).is_file():
        return Path(path).read_text(encoding="utf-8")

    raw = os.getenv(env_name)
    return raw.replace("\\n", "\n") if raw else None


@dataclass(frozen=True)
class Settings:
    """Immutable view of the runtime configuration."""

    service_name: str
    environment: str
    database_url: str
    jwt_issuer: str
    jwt_audience: str
    access_token_ttl_seconds: int
    refresh_token_ttl_seconds: int
    jwt_private_key: str | None
    jwt_public_key: str | None
    log_level: str


def load_settings(service_name: str) -> Settings:
    """Build the settings object for one service. Called once at import time."""
    return Settings(
        service_name=service_name,
        environment=os.getenv("ENVIRONMENT", "local"),
        database_url=os.getenv("DATABASE_URL", "sqlite:///./local.db"),
        jwt_issuer=os.getenv("JWT_ISSUER", "showcase-auth"),
        jwt_audience=os.getenv("JWT_AUDIENCE", "showcase-api"),
        access_token_ttl_seconds=int(os.getenv("ACCESS_TOKEN_TTL_SECONDS", "900")),
        refresh_token_ttl_seconds=int(os.getenv("REFRESH_TOKEN_TTL_SECONDS", "604800")),
        jwt_private_key=_read_pem("JWT_PRIVATE_KEY", "JWT_PRIVATE_KEY_PATH"),
        jwt_public_key=_read_pem("JWT_PUBLIC_KEY", "JWT_PUBLIC_KEY_PATH"),
        log_level=os.getenv("LOG_LEVEL", "INFO"),
    )
