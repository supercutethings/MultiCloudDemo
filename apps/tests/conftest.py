"""Shared pytest fixtures: one RSA key pair and an isolated in-memory database.

Environment variables are set at import time because each service builds its
settings when its module is imported -- the same way a container does at boot.
"""

from __future__ import annotations

import os

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

PRIVATE_PEM = _KEY.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode()

PUBLIC_PEM = (
    _KEY.public_key()
    .public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    .decode()
)

os.environ.update(
    {
        "ENVIRONMENT": "test",
        "LOG_LEVEL": "WARNING",
        "DATABASE_URL": "sqlite://",
        "JWT_ISSUER": "showcase-auth",
        "JWT_AUDIENCE": "showcase-api",
        "JWT_PRIVATE_KEY": PRIVATE_PEM,
        "JWT_PUBLIC_KEY": PUBLIC_PEM,
        "AUTH_SERVICE_URL": "http://auth.invalid",
        "CATALOG_SERVICE_URL": "http://catalog.invalid",
    }
)
