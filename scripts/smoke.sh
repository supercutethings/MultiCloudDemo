#!/usr/bin/env bash
# End-to-end smoke test: register -> login -> authenticated CRUD through the edge.
# Works against docker compose (localhost:8080) and against a deployed ALB URL.
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
EMAIL="smoke-$(date +%s)@example.com"
PASSWORD="correct-horse-battery"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

say "index"
curl -fsS "$BASE_URL/" | jq -e '.service == "gateway"' >/dev/null || fail "gateway index"

say "register $EMAIL"
curl -fsS -X POST "$BASE_URL/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null || fail "register"

say "login"
TOKENS=$(curl -fsS -X POST "$BASE_URL/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN=$(jq -er '.access_token' <<<"$TOKENS") || fail "no access_token"
REFRESH=$(jq -er '.refresh_token' <<<"$TOKENS") || fail "no refresh_token"

say "identity"
ME=$(curl -fsS "$BASE_URL/auth/me" -H "Authorization: Bearer $TOKEN")
jq -e --arg e "$EMAIL" '.email == $e' <<<"$ME" >/dev/null || fail "/auth/me email mismatch"

say "unauthenticated catalog call must be rejected"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/catalog/items")
[[ "$CODE" == "401" ]] || fail "expected 401 without a token, got $CODE"

say "create item"
ITEM=$(curl -fsS -X POST "$BASE_URL/catalog/items" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"smoke item","description":"created by scripts/smoke.sh","price_cents":1999}')
ITEM_ID=$(jq -er '.id' <<<"$ITEM") || fail "no item id"

say "list items"
COUNT=$(curl -fsS "$BASE_URL/catalog/items" -H "Authorization: Bearer $TOKEN" | jq 'length')
[[ "$COUNT" -ge 1 ]] || fail "item list is empty"

say "refresh token"
curl -fsS -X POST "$BASE_URL/auth/refresh" \
  -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$REFRESH\"}" | jq -e '.access_token' >/dev/null || fail "refresh"

say "delete item"
curl -fsS -X DELETE "$BASE_URL/catalog/items/$ITEM_ID" -H "Authorization: Bearer $TOKEN" \
  -o /dev/null || fail "delete"

printf '\033[32mAll smoke checks passed against %s\033[0m\n' "$BASE_URL"
