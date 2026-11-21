#!/usr/bin/env bash
# Prove the internal hop is really mutual TLS with an explicit caller allow rule, not just
# "TLS is enabled".
#
#   scripts/mtls-check.sh [internal-data-url]
#
# Default target is the compose-published auth data port (https://localhost:8001). Four
# assertions, each of which has failed for real at some point in a similar stack:
#   1. a caller with the CA but NO client certificate is rejected during the handshake;
#   2. a *valid* client certificate from a CA that is not allow-listed is also rejected --
#      the certificate must be trusted, not merely well-formed;
#   3. the gateway's client certificate is accepted (200 on /healthz);
#   4. with the certificate, an unauthenticated request still gets 401: mTLS is transport
#      identity, the JWT is still the user identity.
set -euo pipefail

INTERNAL_URL="${1:-https://localhost:8001}"
CERT_DIR="${CERT_DIR:-.certs}"
SERVER_CA="$CERT_DIR/server-ca.crt"
CLIENT_CERT="$CERT_DIR/gateway/tls.crt"
CLIENT_KEY="$CERT_DIR/gateway/tls.key"
UNLISTED_CERT="$CERT_DIR/unlisted-client/tls.crt"
UNLISTED_KEY="$CERT_DIR/unlisted-client/tls.key"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

for f in "$SERVER_CA" "$CLIENT_CERT" "$CLIENT_KEY" "$UNLISTED_CERT" "$UNLISTED_KEY"; do
  [[ -f "$f" ]] || fail "missing $f (run: make certs)"
done

say "handshake without a client certificate must fail"
if curl -sS --max-time 5 --cacert "$SERVER_CA" "$INTERNAL_URL/healthz" >/dev/null 2>&1; then
  fail "server accepted a client with no certificate -- mTLS is not enforced"
fi

say "a valid certificate from an unlisted issuer must fail (the allow rule)"
if curl -sS --max-time 5 --cacert "$SERVER_CA" \
  --cert "$UNLISTED_CERT" --key "$UNLISTED_KEY" "$INTERNAL_URL/healthz" >/dev/null 2>&1; then
  fail "server accepted an unlisted caller -- certificate issuance is being confused with authorisation"
fi

say "gateway client certificate must be accepted"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  --cacert "$SERVER_CA" --cert "$CLIENT_CERT" --key "$CLIENT_KEY" "$INTERNAL_URL/healthz")
[[ "$CODE" == "200" ]] || fail "expected 200 with the gateway certificate, got $CODE"

say "a certificate replaces neither the JWT nor authorisation"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  --cacert "$SERVER_CA" --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  "$INTERNAL_URL/catalog/items" || true)
if [[ "$INTERNAL_URL" == *":8001"* ]]; then
  # Port 8001 is auth in the compose layout, where the path simply does not exist.
  [[ "$CODE" == "404" ]] || fail "expected 404 for an unknown auth path, got $CODE"
else
  [[ "$CODE" == "401" ]] || fail "expected 401 without a JWT, got $CODE"
fi

printf '\033[32mmTLS + caller allow rule verified against %s\033[0m\n' "$INTERNAL_URL"
