#!/usr/bin/env bash
# Report the remaining lifetime of the internal certificates, and fail when one is close
# enough to expiry to break a handshake.
#
#   scripts/cert-expiry.sh                    # the local .certs tree
#   scripts/cert-expiry.sh /path/to/certs
#   scripts/cert-expiry.sh --kube             # Secrets in the showcase namespace
#
# Prometheus owns the alerting in a cluster (k8s/monitoring/certificates.yaml). This script
# exists for the two places Prometheus is not: a laptop and a CI job with no cluster.
#
# Exit status: 0 when every certificate is comfortably valid, 1 when any expires within
# FAIL_DAYS (default 7) or is already expired. Warnings (default 21 days) do not fail.
set -euo pipefail

WARN_DAYS="${WARN_DAYS:-21}"
FAIL_DAYS="${FAIL_DAYS:-7}"
NAMESPACE="${NAMESPACE:-showcase}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
note() { printf '\033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '\033[33mwarn\033[0m  %s\n' "$*"; }
bad() { printf '\033[31mfail\033[0m  %s\n' "$*"; }

if [[ "${1:-}" == "--kube" ]]; then
  command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  say "reading tls.crt from Secrets in namespace $NAMESPACE"
  for secret in $(kubectl -n "$NAMESPACE" get secrets -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | grep -q .; then
      kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath='{.data.tls\.crt}' \
        | base64 -d > "$TMP/$secret.crt" 2>/dev/null || true
    fi
    if kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | grep -q .; then
      kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath='{.data.ca\.crt}' \
        | base64 -d > "$TMP/$secret-ca.crt" 2>/dev/null || true
    fi
  done
  CERT_DIR="$TMP"
else
  CERT_DIR="${1:-.certs}"
fi

[[ -d "$CERT_DIR" ]] || { echo "no such directory: $CERT_DIR (run: make certs)" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

say "checking certificates under $CERT_DIR (warn < ${WARN_DAYS}d, fail < ${FAIL_DAYS}d)"

failed=0
checked=0
while IFS= read -r file; do
  # `-checkend` is portable across OpenSSL and LibreSSL, unlike parsing -enddate with date(1).
  if ! openssl x509 -in "$file" -noout 2>/dev/null; then
    warn "$file is not a readable PEM certificate (skipped)"
    continue
  fi
  checked=$((checked + 1))
  subject="$(openssl x509 -in "$file" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  expiry="$(openssl x509 -in "$file" -noout -enddate 2>/dev/null | cut -d= -f2-)"
  label="$file ($subject, expires $expiry)"

  if ! openssl x509 -in "$file" -noout -checkend $((FAIL_DAYS * 86400)) >/dev/null 2>&1; then
    bad "$label"
    failed=1
  elif ! openssl x509 -in "$file" -noout -checkend $((WARN_DAYS * 86400)) >/dev/null 2>&1; then
    warn "$label"
  else
    note "$label"
  fi
done < <(find "$CERT_DIR" -type f \( -name '*.crt' -o -name '*.pem' \) | sort)

(( checked > 0 )) || { echo "no certificates found under $CERT_DIR" >&2; exit 1; }

if (( failed )); then
  printf '\033[31m%d certificate(s) checked, at least one is too close to expiry\033[0m\n' "$checked"
  exit 1
fi
printf '\033[32m%d certificate(s) checked, all valid beyond %d days\033[0m\n' "$checked" "$FAIL_DAYS"
