#!/usr/bin/env bash
# Render one cloud overlay to stdout, substituting the account-specific values that must
# never be committed (VPC CIDRs, certificate ARNs, project ids, image registries).
#
#   scripts/k8s-render.sh eks > /tmp/eks.yaml
#   IMAGE_REPO=... scripts/k8s-render.sh eks | kubectl apply -f -
#
# Everything else about the deployment is identical across the three clouds -- that is the
# point of the overlay structure. If a value is missing the script fails before printing a
# single line of YAML, which is cheaper than a half-deployed cluster.
set -euo pipefail

CLOUD="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "$CLOUD" in
  eks) REQUIRED=(AWS_REGION SECRETS_PREFIX CERTIFICATE_ARN VPC_CIDR IMAGE_REPO) ;;
  aks) REQUIRED=(APP_HOST AZURE_KEYVAULT_URI VNET_CIDR IMAGE_REPO) ;;
  gke) REQUIRED=(APP_HOST GCP_PROJECT GCP_REGION GKE_CLUSTER VPC_CIDR STATIC_IP IMAGE_REPO) ;;
  *) die "usage: $(basename "$0") <eks|aks|gke>" ;;
esac

missing=()
for name in "${REQUIRED[@]}"; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
if (( ${#missing[@]} > 0 )); then
  die "missing required environment variables for '$CLOUD': ${missing[*]}"
fi

command -v kubectl >/dev/null || die "kubectl not found (it provides 'kubectl kustomize')"

rendered="$(kubectl kustomize "$ROOT/k8s/overlays/$CLOUD")"

# Substitute __TOKENS__. The `|` delimiter means values must not contain it.
for name in "${REQUIRED[@]}"; do
  [[ "$name" == "IMAGE_REPO" ]] && continue
  value="${!name}"
  case "$value" in
    *'|'*) die "$name must not contain the '|' character" ;;
  esac
  rendered="$(printf '%s\n' "$rendered" | sed "s|__${name}__|${value}|g")"
done

# Point every service image at the real registry (ECR / ACR / Artifact Registry).
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
rendered="$(printf '%s\n' "$rendered" \
  | sed -E "s|ghcr\.io/example/showcase-([a-z]+):1\.0\.0|${IMAGE_REPO}/\1:${IMAGE_TAG}|g")"

# A leftover placeholder means a value silently did not apply. Fail loudly.
leftover="$(printf '%s\n' "$rendered" | grep -o '__[A-Z_]*__' | sort -u | tr '\n' ' ' || true)"
[[ -z "$leftover" ]] || die "unsubstituted placeholders: $leftover"

printf '%s\n' "$rendered"
