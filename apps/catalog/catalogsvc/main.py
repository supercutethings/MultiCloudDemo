"""Catalog service: JWT-protected CRUD, always scoped to the caller's user id.

There is no `owner_id` query parameter anywhere: the owner always comes from the
verified token, which removes a whole class of horizontal privilege escalation
bugs ("just change the id in the URL").
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from common.config import load_settings
from common.db import get_session, init_db, wait_for_db
from common.observability import configure_logging, install_request_context
from common.ops import start_ops_listener, stop_ops_listener

from .deps import require_user
from .models import Item
from .schemas import ItemCreate, ItemResponse, ItemUpdate

__version__ = "1.0.0"

settings = load_settings("catalog")
configure_logging(settings.service_name, settings.log_level)
log = logging.getLogger(__name__)

current_user = require_user(settings)


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Create tables if missing, then wait for the database in non-local envs."""
    init_db(settings.database_url)
    if settings.environment != "local":
        wait_for_db()
    # Probes cannot present a client certificate, so they get their own listener.
    ops = await start_ops_listener(settings.service_name)
    log.info("catalog service ready", extra={"environment": settings.environment})
    yield
    await stop_ops_listener(ops)


app = FastAPI(
    title="Catalog service",
    version=__version__,
    description="CRUD over items owned by the authenticated user.",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
install_request_context(app)


def _get_owned_item(session: Session, item_id: str, user_id: str) -> Item:
    """Fetch an item or fail with 404 -- never 403, so ids cannot be enumerated."""
    item = session.scalar(select(Item).where(Item.id == item_id, Item.owner_id == user_id))
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "item not found")
    return item


@app.get("/healthz", tags=["ops"])
def healthz() -> dict[str, str]:
    """Liveness probe."""
    return {"status": "ok", "service": settings.service_name}


@app.get("/readyz", tags=["ops"])
def readyz(session: Session = Depends(get_session)) -> dict[str, str]:
    """Readiness probe: database reachable."""
    session.execute(select(1))
    return {"status": "ready", "service": settings.service_name}


@app.get("/catalog/items", response_model=list[ItemResponse], tags=["items"])
def list_items(
    session: Session = Depends(get_session),
    user_id: str = Depends(current_user),
) -> list[ItemResponse]:
    """List the caller's items, newest first."""
    items = session.scalars(
        select(Item).where(Item.owner_id == user_id).order_by(Item.created_at.desc())
    ).all()
    return [ItemResponse.model_validate(item, from_attributes=True) for item in items]


@app.post(
    "/catalog/items",
    response_model=ItemResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["items"],
)
def create_item(
    payload: ItemCreate,
    session: Session = Depends(get_session),
    user_id: str = Depends(current_user),
) -> ItemResponse:
    """Create an item owned by the caller."""
    item = Item(owner_id=user_id, **payload.model_dump())
    session.add(item)
    session.commit()
    return ItemResponse.model_validate(item, from_attributes=True)


@app.get("/catalog/items/{item_id}", response_model=ItemResponse, tags=["items"])
def get_item(
    item_id: str,
    session: Session = Depends(get_session),
    user_id: str = Depends(current_user),
) -> ItemResponse:
    """Read a single item owned by the caller."""
    item = _get_owned_item(session, item_id, user_id)
    return ItemResponse.model_validate(item, from_attributes=True)


@app.put("/catalog/items/{item_id}", response_model=ItemResponse, tags=["items"])
def update_item(
    item_id: str,
    payload: ItemUpdate,
    session: Session = Depends(get_session),
    user_id: str = Depends(current_user),
) -> ItemResponse:
    """Partially update an item owned by the caller."""
    item = _get_owned_item(session, item_id, user_id)
    for field, value in payload.model_dump(exclude_none=True).items():
        setattr(item, field, value)
    session.commit()
    return ItemResponse.model_validate(item, from_attributes=True)


@app.delete("/catalog/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["items"])
def delete_item(
    item_id: str,
    session: Session = Depends(get_session),
    user_id: str = Depends(current_user),
) -> Response:
    """Delete an item owned by the caller."""
    session.delete(_get_owned_item(session, item_id, user_id))
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
