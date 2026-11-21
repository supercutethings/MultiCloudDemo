"""Edge behaviour of the gateway that does not need the upstream services."""

from __future__ import annotations

from fastapi.testclient import TestClient

from gateway.main import app


def test_index_lists_routes() -> None:
    with TestClient(app) as client:
        body = client.get("/").json()
        assert body["service"] == "gateway"
        assert "POST /auth/login" in body["routes"]


def test_catalog_requires_a_token_before_reaching_upstream() -> None:
    with TestClient(app) as client:
        response = client.get("/catalog/items")
        assert response.status_code == 401
        assert response.headers["WWW-Authenticate"] == "Bearer"


def test_invalid_token_is_rejected_at_the_edge() -> None:
    with TestClient(app) as client:
        response = client.get("/catalog/items", headers={"Authorization": "Bearer tampered"})
        assert response.status_code == 401


def test_healthz() -> None:
    with TestClient(app) as client:
        assert client.get("/healthz").json()["status"] == "ok"
