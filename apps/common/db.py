"""Thin SQLAlchemy helpers: engine creation, schema bootstrap, session scope.

Deliberately small. Each service owns its tables and imports only these helpers,
so there is no shared ORM "god module" coupling the services together.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Iterator

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
from sqlalchemy.pool import StaticPool

log = logging.getLogger(__name__)


class Base(DeclarativeBase):
    """Declarative base for the tables owned by a single service."""


_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def make_engine(database_url: str) -> Engine:
    """Create an engine with settings appropriate for the backend in use."""
    if database_url.startswith("sqlite"):
        # Tests use an in-memory database shared across threads.
        if ":memory:" in database_url or database_url.rstrip("/") == "sqlite:":
            return create_engine(
                database_url,
                connect_args={"check_same_thread": False},
                poolclass=StaticPool,
            )
        return create_engine(database_url, connect_args={"check_same_thread": False})

    return create_engine(database_url, pool_pre_ping=True, pool_size=5, max_overflow=5)


def init_db(database_url: str) -> None:
    """Store the process-wide engine and create tables that do not exist yet.

    Fine for a demo. A production system replaces this with versioned migrations
    (Alembic) run as a separate pre-deploy step -- noted in docs/adr/0003.
    """
    global _engine, _session_factory
    _engine = make_engine(database_url)
    Base.metadata.create_all(_engine)
    _session_factory = sessionmaker(bind=_engine, expire_on_commit=False, autoflush=False)


def get_session() -> Iterator[Session]:
    """FastAPI dependency that yields a session and always closes it."""
    if _session_factory is None:
        raise RuntimeError("init_db() must run before the first request (see lifespan)")
    session = _session_factory()
    try:
        yield session
    finally:
        session.close()


def ping() -> None:
    """Raise if the database does not answer; used by the ops readiness probe."""
    if _engine is None:
        raise RuntimeError("init_db() must run before ping()")
    with _engine.connect() as conn:
        conn.execute(text("SELECT 1"))


def wait_for_db(attempts: int = 30, delay_seconds: float = 2.0) -> None:
    """Block until the database accepts connections (container start-up ordering)."""
    if _engine is None:
        raise RuntimeError("init_db() must run before wait_for_db()")
    for attempt in range(1, attempts + 1):
        try:
            with _engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return
        except Exception as exc:  # noqa: BLE001 - any driver error means "not ready"
            log.warning("database not ready (attempt %s/%s): %s", attempt, attempts, exc)
            time.sleep(delay_seconds)
    raise RuntimeError("database did not become ready in time")
