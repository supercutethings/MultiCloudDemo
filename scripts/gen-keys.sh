#!/usr/bin/env bash
# Generate the RS256 key pair used by the auth service (local development only).
# In the cloud the same pair is created by Terraform and stored in the provider's
# secret manager -- never in the repository.
set -euo pipefail

KEY_DIR="${1:-.keys}"

mkdir -p "$KEY_DIR"

if [[ -f "$KEY_DIR/jwt-private.pem" && -f "$KEY_DIR/jwt-public.pem" ]]; then
  echo "keys already present in $KEY_DIR (delete them to rotate)"
  exit 0
fi

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY_DIR/jwt-private.pem" 2>/dev/null
openssl rsa -in "$KEY_DIR/jwt-private.pem" -pubout -out "$KEY_DIR/jwt-public.pem" 2>/dev/null
chmod 600 "$KEY_DIR/jwt-private.pem"

echo "generated $KEY_DIR/jwt-private.pem and $KEY_DIR/jwt-public.pem"
