#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$repo_root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$repo_root/.env"
  set +a
fi

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-Urbanquest}"
LOCATION="${LOCATION:-swedencentral}"
CONTAINERAPP_ENV="${CONTAINERAPP_ENV:-hermes-env}"
CONTAINERAPP_NAME="${CONTAINERAPP_NAME:-hermes-agent}"
OPENCLAW_IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-latest}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.5.7}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
OPENCLAW_UPLOAD_LOCAL_STATE="${OPENCLAW_UPLOAD_LOCAL_STATE:-false}"
ACR_PULL_IDENTITY="${ACR_PULL_IDENTITY:-hermes-acr-pull}"

if [[ -z "$OPENCLAW_GATEWAY_TOKEN" ]]; then
  OPENCLAW_GATEWAY_TOKEN="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
fi

require ACR_NAME
require STORAGE_ACCOUNT
require FILE_SHARE
require SLACK_BOT_TOKEN
require SLACK_APP_TOKEN
require SLACK_ALLOWED_USERS

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI is required." >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst is required. On macOS: brew install gettext && brew link --force gettext" >&2
  exit 1
fi

az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

if ! az acr show --name "$ACR_NAME" >/dev/null 2>&1; then
  az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --sku Basic \
    --admin-enabled false \
    --output none
fi

az provider register --namespace Microsoft.ManagedIdentity --wait

if ! az identity show --resource-group "$RESOURCE_GROUP" --name "$ACR_PULL_IDENTITY" >/dev/null 2>&1; then
  az identity create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_PULL_IDENTITY" \
    --location "$LOCATION" \
    --output none
fi

ACR_PULL_ID="$(
  az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_PULL_IDENTITY" \
    --query id \
    --output tsv
)"
ACR_PULL_PRINCIPAL_ID="$(
  az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_PULL_IDENTITY" \
    --query principalId \
    --output tsv
)"
acr_id="$(az acr show --name "$ACR_NAME" --query id --output tsv)"
az role assignment create \
  --assignee-object-id "$ACR_PULL_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role AcrPull \
  --scope "$acr_id" \
  --output none || true

if [[ "${OPENCLAW_SKIP_IMAGE_BUILD:-false}" != "true" ]]; then
  az acr build \
    --registry "$ACR_NAME" \
    --image "openclaw-agent:$OPENCLAW_IMAGE_TAG" \
    --build-arg "OPENCLAW_VERSION=$OPENCLAW_VERSION" \
    "$repo_root"
fi

if ! az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$CONTAINERAPP_ENV" >/dev/null 2>&1; then
  az containerapp env create \
    --name "$CONTAINERAPP_ENV" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
fi

if ! az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  az storage account create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$STORAGE_ACCOUNT" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --output none
fi

storage_key="$(
  az storage account keys list \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT" \
    --query '[0].value' \
    --output tsv
)"

az storage share-rm create \
  --resource-group "$RESOURCE_GROUP" \
  --storage-account "$STORAGE_ACCOUNT" \
  --name "$FILE_SHARE" \
  --quota 5 \
  --output none || true

az containerapp env storage set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINERAPP_ENV" \
  --storage-name openclaw-home \
  --access-mode ReadWrite \
  --azure-file-account-name "$STORAGE_ACCOUNT" \
  --azure-file-account-key "$storage_key" \
  --azure-file-share-name "$FILE_SHARE" \
  --output none

for old_path in config.yaml SOUL.md google_client_secret.json google_token.json; do
  az storage file delete \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$storage_key" \
    --share-name "$FILE_SHARE" \
    --path "$old_path" \
    --output none 2>/dev/null || true
done

az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$FILE_SHARE" \
  --source "$repo_root/config/openclaw.json" \
  --path openclaw.json \
  --output none

if [[ "$OPENCLAW_UPLOAD_LOCAL_STATE" == "true" && -d "$repo_root/data" ]]; then
  az storage file upload-batch \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$storage_key" \
    --destination "$FILE_SHARE" \
    --source "$repo_root/data" \
    --output none
fi

ACR_LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)"
CONTAINERAPP_ENV_ID="$(
  az containerapp env show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINERAPP_ENV" \
    --query id \
    --output tsv
)"

OPENCLAW_CONFIG_DIGEST="$(
  {
    shasum -a 256 "$repo_root/config/openclaw.json"
    printf '%s' "$SLACK_ALLOWED_USERS" | shasum -a 256
  } | shasum -a 256 | awk '{print $1}'
)"

tmp_dir="$repo_root/.azure-tmp"
mkdir -p "$tmp_dir"
tmp_yaml="$tmp_dir/containerapp.yaml"

export ACR_LOGIN_SERVER ACR_PULL_ID CONTAINERAPP_ENV_ID
export OPENCLAW_IMAGE_TAG OPENCLAW_CONFIG_DIGEST OPENCLAW_GATEWAY_TOKEN
export SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS

envsubst '$ACR_LOGIN_SERVER $ACR_PULL_ID $CONTAINERAPP_ENV_ID $OPENCLAW_IMAGE_TAG $OPENCLAW_CONFIG_DIGEST $OPENCLAW_GATEWAY_TOKEN $SLACK_BOT_TOKEN $SLACK_APP_TOKEN $SLACK_ALLOWED_USERS' \
  < "$repo_root/azure/containerapp.yaml.tpl" > "$tmp_yaml"

if az containerapp show --resource-group "$RESOURCE_GROUP" --name "$CONTAINERAPP_NAME" >/dev/null 2>&1; then
  az containerapp update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINERAPP_NAME" \
    --yaml "$tmp_yaml" \
    --output none
else
  az containerapp create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINERAPP_NAME" \
    --environment "$CONTAINERAPP_ENV" \
    --yaml "$tmp_yaml" \
    --output none
fi

principal_id="$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$CONTAINERAPP_NAME" --query identity.principalId --output tsv)"
if [[ -n "$principal_id" && "$principal_id" != "null" ]]; then
  az role assignment create \
    --assignee "$principal_id" \
    --role AcrPull \
    --scope "$acr_id" \
    --output none || true

  az containerapp update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINERAPP_NAME" \
    --image "$ACR_LOGIN_SERVER/openclaw-agent:$OPENCLAW_IMAGE_TAG" \
    --output none
fi

echo "Azure OpenClaw deployment finished."
echo "Logs: az containerapp logs show -g $RESOURCE_GROUP -n $CONTAINERAPP_NAME --follow"
