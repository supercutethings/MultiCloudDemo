#!/usr/bin/env bash
# Generate the local PKI for the internal mTLS links (development only).
#
# Two trust domains, not one shared CA:
#
#   .certs/server-ca.{crt,key}      signs what services *present*   -> the gateway trusts it
#   .certs/auth/tls.{crt,key}       server leaf, SANs: auth, *.showcase.svc, localhost
#   .certs/catalog/tls.{crt,key}    server leaf, SANs: catalog, *.showcase.svc, localhost
#
#   .certs/client-ca.{crt,key}      one CA per *caller identity*    -> services trust it
#   .certs/gateway/tls.{crt,key}    client leaf for the gateway (clientAuth only)
#
#   .certs/rogue-ca.{crt,key}       an identity nobody allow-listed  -> must be refused
#   .certs/unlisted-client/tls.*    a perfectly valid client cert that must still fail
#
# Why one CA per caller identity instead of one shared CA: uvicorn does not expose the
# peer certificate to the ASGI application, so "is this caller allowed?" can only be
# answered during the handshake. A server is handed the bundle of CAs it accepts; a caller
# gets in only if its issuer is in that bundle. Onboarding a service is therefore an
# explicit, reviewable allow rule -- not a side effect of being issued a certificate.
#
# The CA keys stay here and are never mounted into a container: services get a leaf and
# the CA *certificate* of their peers, so a compromised pod cannot mint a new identity.
# In the cloud the same hierarchy is produced by infra/modules/pki (ECS) or cert-manager
# (Kubernetes).
#
#   scripts/gen-certs.sh              # idempotent
#   scripts/gen-certs.sh .certs --force
set -euo pipefail

CERT_DIR="${1:-.certs}"
FORCE="${2:-}"
DAYS=365

if [[ -f "$CERT_DIR/server-ca.crt" && "$FORCE" != "--force" ]]; then
  echo "certificates already present in $CERT_DIR (pass --force to rotate)"
  exit 0
fi

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# Extension file, not -addext: LibreSSL (the openssl shipped with macOS) accepts -addext
# on `req -x509` and then silently emits a certificate with no CA:TRUE, which every client
# rejects as "unable to get local issuer certificate". `x509 -req -signkey` is supported by
# both LibreSSL and OpenSSL and honours -extfile.
ca() {
  local name="$1" cn="$2"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CERT_DIR/$name.key" 2>/dev/null
  chmod 600 "$CERT_DIR/$name.key"
  openssl req -new -key "$CERT_DIR/$name.key" -subj "/CN=$cn/O=Showcase Platform" \
    -out "$CERT_DIR/$name.csr" 2>/dev/null
  cat > "$CERT_DIR/$name-ext.cnf" <<EOF
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
EOF
  openssl x509 -req -in "$CERT_DIR/$name.csr" -signkey "$CERT_DIR/$name.key" -sha256 -days 3650 \
    -extfile "$CERT_DIR/$name-ext.cnf" -out "$CERT_DIR/$name.crt" 2>/dev/null
  rm -f "$CERT_DIR/$name.csr" "$CERT_DIR/$name-ext.cnf"
  echo "issued CA $name"
}

issue() {
  local name="$1" cn="$2" eku="$3" sans="$4" signer="$5"
  local dir="$CERT_DIR/$name"
  mkdir -p "$dir"

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/tls.key" 2>/dev/null
  chmod 600 "$dir/tls.key"
  openssl req -new -key "$dir/tls.key" -subj "/CN=$cn/O=Showcase Platform" -out "$dir/tls.csr" 2>/dev/null

  # Written to a file rather than -addext because LibreSSL (macOS openssl) is uneven there.
  cat > "$dir/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=$eku
subjectAltName=$sans
EOF

  openssl x509 -req -in "$dir/tls.csr" -CA "$CERT_DIR/$signer.crt" -CAkey "$CERT_DIR/$signer.key" \
    -CAcreateserial -days "$DAYS" -sha256 -extfile "$dir/ext.cnf" -out "$dir/tls.crt" 2>/dev/null
  rm -f "$dir/tls.csr" "$dir/ext.cnf"
  echo "issued $name ($eku, signed by $signer)"
}

ca server-ca showcase-dev-server-ca
ca client-ca showcase-dev-client-ca
ca rogue-ca showcase-dev-rogue-ca

LOCAL="DNS:localhost,IP:127.0.0.1"
issue auth auth serverAuth \
  "DNS:auth,DNS:auth.showcase.svc,DNS:auth.showcase.svc.cluster.local,$LOCAL" server-ca
issue catalog catalog serverAuth \
  "DNS:catalog,DNS:catalog.showcase.svc,DNS:catalog.showcase.svc.cluster.local,$LOCAL" server-ca
issue gateway gateway clientAuth "DNS:gateway" client-ca
issue unlisted-client unlisted-client clientAuth "DNS:unlisted-client" rogue-ca

# Fail here rather than at 2am inside a pod: every leaf must chain to its intended CA.
for leaf in auth catalog; do
  openssl verify -CAfile "$CERT_DIR/server-ca.crt" "$CERT_DIR/$leaf/tls.crt" >/dev/null \
    || { echo "verification failed for $leaf against server-ca" >&2; exit 1; }
done
openssl verify -CAfile "$CERT_DIR/client-ca.crt" "$CERT_DIR/gateway/tls.crt" >/dev/null \
  || { echo "verification failed for gateway against client-ca" >&2; exit 1; }

# The negative case is as important as the positive one: a valid client certificate from
# an issuer that is not in the servers' trust bundle must NOT verify. If this succeeds,
# the allow rule is not really a rule.
if openssl verify -CAfile "$CERT_DIR/client-ca.crt" "$CERT_DIR/unlisted-client/tls.crt" >/dev/null 2>&1; then
  echo "unlisted caller verified against client-ca -- the allow rule would be bypassable" >&2
  exit 1
fi
openssl verify -CAfile "$CERT_DIR/rogue-ca.crt" "$CERT_DIR/unlisted-client/tls.crt" >/dev/null \
  || { echo "unlisted-client leaf does not chain to its own CA" >&2; exit 1; }

for name in server-ca client-ca rogue-ca; do
  openssl x509 -in "$CERT_DIR/$name.crt" -noout -text | grep -q "CA:TRUE" \
    || { echo "generated $name is not a CA (LibreSSL -addext trap?)" >&2; exit 1; }
done

echo "3 CAs + 4 verified leaf certificates written to $CERT_DIR"
