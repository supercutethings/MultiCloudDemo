"""Request/response contracts for the auth service."""

from __future__ import annotations

from pydantic import BaseModel, Field

from common.security import MIN_PASSWORD_LENGTH


class RegisterRequest(BaseModel):
    email: str = Field(min_length=3, max_length=320, examples=["dev@example.com"])
    password: str = Field(min_length=MIN_PASSWORD_LENGTH, max_length=128)


class LoginRequest(BaseModel):
    email: str = Field(examples=["dev@example.com"])
    password: str


class RefreshRequest(BaseModel):
    refresh_token: str


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class UserResponse(BaseModel):
    id: str
    email: str
