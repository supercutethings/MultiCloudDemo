"""API tests for the auth service."""

from __future__ import annotations

from fastapi.testclient import TestClient

from authsvc.main import app


def _register(client: TestClient, email: str = "dev@example.com") -> None:
    response = client.post("/auth/register", json={"email": email, "password": "password-1234"})
    assert response.status_code == 201, response.text


def test_register_login_and_identify() -> None:
    with TestClient(app) as client:
        _register(client)

        login = client.post(
            "/auth/login", json={"email": "dev@example.com", "password": "password-1234"}
        )
        assert login.status_code == 200, login.text
        body = login.json()
        assert body["token_type"] == "bearer"
        assert body["expires_in"] > 0

        me = client.get("/auth/me", headers={"Authorization": f"Bearer {body['access_token']}"})
        assert me.status_code == 200
        assert me.json()["email"] == "dev@example.com"


def test_duplicate_email_is_conflict() -> None:
    with TestClient(app) as client:
        _register(client, "duplicate@example.com")
        second = client.post(
            "/auth/register",
            json={"email": "duplicate@example.com", "password": "password-1234"},
        )
        assert second.status_code == 409


def test_wrong_password_is_unauthorized() -> None:
    with TestClient(app) as client:
        _register(client, "wrongpass@example.com")
        response = client.post(
            "/auth/login",
            json={"email": "wrongpass@example.com", "password": "not-the-password"},
        )
        assert response.status_code == 401
        assert response.headers["WWW-Authenticate"] == "Bearer"


def test_unknown_user_is_unauthorized() -> None:
    with TestClient(app) as client:
        response = client.post(
            "/auth/login", json={"email": "ghost@example.com", "password": "password-1234"}
        )
        assert response.status_code == 401


def test_refresh_rotates_tokens() -> None:
    with TestClient(app) as client:
        _register(client, "refresh@example.com")
        tokens = client.post(
            "/auth/login", json={"email": "refresh@example.com", "password": "password-1234"}
        ).json()

        refreshed = client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
        assert refreshed.status_code == 200
        assert refreshed.json()["access_token"]


def test_me_requires_a_token() -> None:
    with TestClient(app) as client:
        assert client.get("/auth/me").status_code == 401


def test_health_endpoints() -> None:
    with TestClient(app) as client:
        assert client.get("/healthz").json()["status"] == "ok"
        assert client.get("/readyz").json()["status"] == "ready"
