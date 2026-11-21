"""Request/response contracts for the catalog service."""

from __future__ import annotations

from pydantic import BaseModel, Field


class ItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120, examples=["Terraform sticker"])
    description: str = Field(default="", max_length=2000)
    price_cents: int = Field(default=0, ge=0, le=10_000_000)


class ItemUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=2000)
    price_cents: int | None = Field(default=None, ge=0, le=10_000_000)


class ItemResponse(BaseModel):
    id: str
    name: str
    description: str
    price_cents: int
