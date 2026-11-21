"""API tests for the catalog service, including tenant isolation."""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from catalogsvc.main import app, settings
from common.security import create_token


def _headers(user_id: str) -> dict[str, str]:
    token, _ = create_token(settings, user_id)
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client


def test_requires_a_token(client: TestClient) -> None:
    assert client.get("/catalog/items").status_code == 401
    assert client.post("/catalog/items", json={"name": "x"}).status_code == 401


def test_crud_round_trip(client: TestClient) -> None:
    alice = _headers("alice")

    created = client.post(
        "/catalog/items",
        json={"name": "Terraform sticker", "description": "matte", "price_cents": 500},
        headers=alice,
    )
    assert created.status_code == 201, created.text
    item = created.json()
    assert item["price_cents"] == 500

    assert client.get(f"/catalog/items/{item['id']}", headers=alice).json()["name"] == (
        "Terraform sticker"
    )

    updated = client.put(f"/catalog/items/{item['id']}", json={"price_cents": 750}, headers=alice)
    assert updated.status_code == 200
    assert updated.json()["price_cents"] == 750
    assert updated.json()["name"] == "Terraform sticker"

    listing = client.get("/catalog/items", headers=alice).json()
    assert any(row["id"] == item["id"] for row in listing)

    assert client.delete(f"/catalog/items/{item['id']}", headers=alice).status_code == 204
    assert client.get(f"/catalog/items/{item['id']}", headers=alice).status_code == 404


def test_items_are_isolated_between_users(client: TestClient) -> None:
    alice, bob = _headers("alice"), _headers("bob")

    item = client.post("/catalog/items", json={"name": "alice's"}, headers=alice).json()

    # Bob must not see, read, modify or delete Alice's item -- and gets 404, not 403.
    assert client.get(f"/catalog/items/{item['id']}", headers=bob).status_code == 404
    assert (
        client.put(
            f"/catalog/items/{item['id']}", json={"name": "hijacked"}, headers=bob
        ).status_code
        == 404
    )
    assert client.delete(f"/catalog/items/{item['id']}", headers=bob).status_code == 404
    assert all(row["id"] != item["id"] for row in client.get("/catalog/items", headers=bob).json())


def test_invalid_token_is_rejected(client: TestClient) -> None:
    assert client.get("/catalog/items", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_health_endpoints(client: TestClient) -> None:
    assert client.get("/healthz").json()["status"] == "ok"
    assert client.get("/readyz").json()["status"] == "ready"
