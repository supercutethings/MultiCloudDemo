#!/usr/bin/env bash
# One-time Azure bootstrap for CI: state storage, an Entra ID app registration and the
# federated credentials that let GitHub Actions authenticate without a stored secret.
#
#   scripts/azure-oidc-bootstrap.sh --owner <org> --repo <repo>
#
# Idempotent: running it twice updates nothing and re-prints the same values. It requires
# the `az` CLI logged in as someone who can create app registrations and role assignments
# (Application Administrator + Owner/User Access Administrator on the subscription).
#
# What it creates, and why each piece is needed:
#   * a resource group + storage account + container for Terraform state (azurerm backend
#     locks a state blob with a lease, so no separate lock table is required);
#   * an app registration with three federated credentials -- one for pull requests (plan),
#     one for the `azure-dev` environment (apply), one for a manual run on main. These are
#     the only three subjects GitHub can present for this repository;
#   * Contributor + User Access Administrator on the subscription. The second role is not
#     optional: the modules create role assignments (AcrPull, Key Vault Secrets User,
#     deployer access to the vault), and a principal without it fails halfway through an
#     apply with an authorisation error that looks like a bug in the module.
#
# Nothing here is a secret. The output is the list of repository variables to set.

set -euo pipefail

OWNER=""
REPO=""
LOCATION="${LOCATION:-westeurope}"
STATE_RG="${STATE_RG:-showcase-tfstate}"
STATE_SA="${STATE_SA:-showcasetfstate}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
APP_NAME="${APP_NAME:-showcase-github-actions}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-azure-dev}"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Options:"
  echo "  --owner <org>       GitHub user or organisation (required)"
  echo "  --repo <name>       Repository name (required)"
  echo "  --location <region> Azure region for the state account (default: westeurope)"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

[ -n "$OWNER" ] && [ -n "$REPO" ] || usage

command -v az >/dev/null || { echo "az CLI not found" >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "run 'az login' first" >&2; exit 1; }

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "subscription: $SUBSCRIPTION_ID"
echo "tenant:       $TENANT_ID"

# --- State backend ----------------------------------------------------------------------

echo "==> state storage"
az group create --name "$STATE_RG" --location "$LOCATION" --output none

az storage account create \
  --name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --encryption-services blob \
  --output none

az storage container create \
  --name "$STATE_CONTAINER" \
  --account-name "$STATE_SA" \
  --auth-mode login \
  --output none

# --- App registration + federated credentials -------------------------------------------

echo "==> app registration"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [ -z "$APP_ID" ] || [ "$APP_ID" = "None" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "    created $APP_ID"
else
  echo "    reusing $APP_ID"
fi

SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)
if [ -z "$SP_OBJECT_ID" ] || [ "$SP_OBJECT_ID" = "None" ]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo "    created service principal $SP_OBJECT_ID"
else
  echo "    reusing service principal $SP_OBJECT_ID"
fi

# GitHub's OIDC `sub` claim. A job that declares `environment: azure-dev` gets the
# environment subject, not the branch subject -- so the apply job needs its own credential.
ISSUER="https://token.actions.githubusercontent.com"
create_credential() {
  local name="$1" subject="$2"
  local body
  body=$(cat <<JSON
{
  "name": "$name",
  "issuer": "$ISSUER",
  "subject": "$subject",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)
  if az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name'].name" -o tsv | grep -q .; then
    echo "    credential $name exists"
  else
    az ad app federated-credential create --id "$APP_ID" --parameters "$body" --output none
    echo "    credential $name created"
  fi
}

create_credential "github-pull-request" "repo:${OWNER}/${REPO}:pull_request"
create_credential "github-main" "repo:${OWNER}/${REPO}:ref:refs/heads/main"
create_credential "github-environment-${ENVIRONMENT_NAME}" "repo:${OWNER}/${REPO}:environment:${ENVIRONMENT_NAME}"

# --- Role assignments -------------------------------------------------------------------

echo "==> role assignments"
assign_role() {
  local role="$1"
  if az role assignment list --assignee "$SP_OBJECT_ID" --role "$role" --scope "/subscriptions/$SUBSCRIPTION_ID" --query '[0].id' -o tsv | grep -q .; then
    echo "    $role already assigned"
  else
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "/subscriptions/$SUBSCRIPTION_ID" \
      --output none
    echo "    $role assigned"
  fi
}

assign_role "Contributor"
assign_role "User Access Administrator"

# --- Output -----------------------------------------------------------------------------

cat <<EOF

Done. Set these repository variables (Settings -> Secrets and variables -> Actions -> Variables):

  AZURE_CLIENT_ID                  = $APP_ID
  AZURE_TENANT_ID                  = $TENANT_ID
  AZURE_SUBSCRIPTION_ID            = $SUBSCRIPTION_ID
  AZURE_TFSTATE_RESOURCE_GROUP     = $STATE_RG
  AZURE_TFSTATE_STORAGE_ACCOUNT    = $STATE_SA
  AZURE_TFSTATE_CONTAINER          = $STATE_CONTAINER

Then create the environment \`${ENVIRONMENT_NAME}\` under Settings -> Environments and add
required reviewers. Until the environment exists, the apply job runs without approval.

Local equivalent of the backend config:

  cd infra/envs/azure/dev
  cat > backend.hcl <<HCL
  resource_group_name  = "$STATE_RG"
  storage_account_name = "$STATE_SA"
  container_name       = "$STATE_CONTAINER"
  HCL
EOF
