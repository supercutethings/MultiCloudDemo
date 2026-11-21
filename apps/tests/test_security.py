"""Unit tests for password hashing and JWT issuing/verification."""

from __future__ import annotations

from dataclasses import replace

import pytest

from common.config import Settings, load_settings
from common.security import (
    TokenError,
    bearer_token,
    create_token,
    decode_token,
    hash_password,
    verify_password,
)


@pytest.fixture
def settings() -> Settings:
    return load_settings("test")


def test_password_round_trip() -> None:
    encoded = hash_password("a-long-enough-password")
    assert encoded.startswith("scrypt$")
    assert verify_password("a-long-enough-password", encoded)
    assert not verify_password("a-long-enough-passwerd", encoded)


def test_password_hashes_are_salted() -> None:
    assert hash_password("a-long-enough-password") != hash_password("a-long-enough-password")


def test_short_password_is_rejected() -> None:
    with pytest.raises(ValueError):
        hash_password("short")


def test_garbage_hash_does_not_raise() -> None:
    assert not verify_password("whatever", "not-a-valid-hash")


def test_access_token_round_trip(settings: Settings) -> None:
    token, ttl = create_token(settings, "user-123", "access", {"email": "dev@example.com"})
    claims = decode_token(settings, token)
    assert claims["sub"] == "user-123"
    assert claims["email"] == "dev@example.com"
    assert claims["type"] == "access"
    assert ttl == settings.access_token_ttl_seconds


def test_refresh_token_cannot_be_used_as_access_token(settings: Settings) -> None:
    token, _ = create_token(settings, "user-123", "refresh")
    with pytest.raises(TokenError):
        decode_token(settings, token, expected_type="access")


def test_expired_token_is_rejected() -> None:
    settings = replace(load_settings("test"), access_token_ttl_seconds=-5)
    token, _ = create_token(settings, "user-123")
    with pytest.raises(TokenError):
        decode_token(settings, token)


def test_tampered_token_is_rejected(settings: Settings) -> None:
    token, _ = create_token(settings, "user-123")
    tampered = token[:-4] + ("AAAA" if token[-4:] != "AAAA" else "BBBB")
    with pytest.raises(TokenError):
        decode_token(settings, tampered)


def test_bearer_parsing(settings: Settings) -> None:
    assert bearer_token("Bearer abc.def.ghi") == "abc.def.ghi"
    assert bearer_token("abc.def.ghi") == "abc.def.ghi"
    with pytest.raises(TokenError):
        bearer_token(None)
    with pytest.raises(TokenError):
        bearer_token("Bearer a b")
