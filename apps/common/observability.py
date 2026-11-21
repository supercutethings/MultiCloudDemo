"""Structured JSON logging plus request correlation IDs.

One log line per event, with a request id that is generated at the edge
(gateway) or honoured when an upstream already sent one. That is what makes logs
from three services readable side by side in CloudWatch / Log Analytics /
Cloud Logging without any extra tracing infrastructure.
"""

from __future__ import annotations

import json
import logging
import sys
import uuid
from contextvars import ContextVar
from datetime import UTC, datetime

from fastapi import FastAPI, Request

REQUEST_ID_HEADER = "X-Request-ID"
request_id_ctx: ContextVar[str] = ContextVar("request_id", default="-")


class JsonFormatter(logging.Formatter):
    """Render log records as single-line JSON."""

    def __init__(self, service_name: str) -> None:
        super().__init__()
        self.service_name = service_name

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.now(UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "service": self.service_name,
            "request_id": request_id_ctx.get(),
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


def configure_logging(service_name: str, level: str = "INFO") -> None:
    """Install a single JSON handler on the root logger."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service_name))

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())

    # Uvicorn's access log duplicates ours and is not JSON; keep only errors.
    logging.getLogger("uvicorn.access").disabled = True


def install_request_context(app: FastAPI) -> None:
    """Add middleware that stamps every request with a correlation id."""

    @app.middleware("http")
    async def request_context(request: Request, call_next):  # type: ignore[no-untyped-def]
        incoming = request.headers.get(REQUEST_ID_HEADER)
        request_id = incoming or str(uuid.uuid4())
        request_id_ctx.set(request_id)
        response = await call_next(request)
        response.headers[REQUEST_ID_HEADER] = request_id
        return response
