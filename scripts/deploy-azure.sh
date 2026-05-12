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
HERMES_IMAGE_TAG="${HERMES_IMAGE_TAG:-latest}"
HERMES_MODEL="${HERMES_MODEL:-gpt-5.4-mini}"
HERMES_TAIL_FILE_LOGS="${HERMES_TAIL_FILE_LOGS:-true}"
ACR_PULL_IDENTITY="${ACR_PULL_IDENTITY:-hermes-acr-pull}"
SLACK_HOME_CHANNEL="${SLACK_HOME_CHANNEL:-}"
SLACK_HOME_CHANNEL_NAME="${SLACK_HOME_CHANNEL_NAME:-}"
AZURE_AI_RESOURCE_GROUP="${AZURE_AI_RESOURCE_GROUP:-$RESOURCE_GROUP}"
AZURE_AI_RESOURCE_NAME="${AZURE_AI_RESOURCE_NAME:-urbanquest-resource}"
COMPOSIO_API_KEY="${COMPOSIO_API_KEY:-}"

require ACR_NAME
require STORAGE_ACCOUNT
require FILE_SHARE
require SLACK_BOT_TOKEN
require SLACK_APP_TOKEN
require SLACK_ALLOWED_USERS

encode_secret_file() {
  local path="$1"
  if [[ -n "$path" && -f "$path" ]]; then
    base64 < "$path" | tr -d '\n'
  else
    printf '%s' "-"
  fi
}

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI is required." >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst is required. On macOS: brew install gettext && brew link --force gettext" >&2
  exit 1
fi

if [[ -z "${AZURE_FOUNDRY_BASE_URL:-}" ]]; then
  azure_ai_endpoint="$(
    az cognitiveservices account show \
      --resource-group "$AZURE_AI_RESOURCE_GROUP" \
      --name "$AZURE_AI_RESOURCE_NAME" \
      --query properties.endpoint \
      --output tsv
  )"
  AZURE_FOUNDRY_BASE_URL="${azure_ai_endpoint%/}/openai/v1"
fi

if [[ -z "${AZURE_FOUNDRY_API_KEY:-}" ]]; then
  AZURE_FOUNDRY_API_KEY="$(
    az cognitiveservices account keys list \
      --resource-group "$AZURE_AI_RESOURCE_GROUP" \
      --name "$AZURE_AI_RESOURCE_NAME" \
      --query key1 \
      --output tsv
  )"
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

hermes_source_dir="$repo_root/.build/hermes-agent"
hermes_build_dir="$repo_root/.azure-tmp/hermes-agent-build"

if [[ "${HERMES_SKIP_IMAGE_BUILD:-false}" != "true" ]]; then
  if [[ ! -d "$hermes_source_dir/.git" ]]; then
    mkdir -p "$(dirname "$hermes_source_dir")"
    git clone https://github.com/NousResearch/hermes-agent.git "$hermes_source_dir"
  fi

  mkdir -p "$hermes_build_dir"
  rsync -a --delete \
    --exclude .git \
    --exclude node_modules \
    --exclude web/node_modules \
    --exclude ui-tui/node_modules \
    "$hermes_source_dir/" "$hermes_build_dir/"

  # ACR Build still rejects Dockerfile frontend COPY --chmod in some regions.
  # Preserve the same runtime permissions with a classic-Docker-compatible RUN.
  perl -0pi -e 's/COPY --chmod=0755 --from=/COPY --from=/g' "$hermes_build_dir/Dockerfile"

  # Avoid Docker Hub anonymous pull limits in ACR Build:
  # - use an MCR Debian 13 base instead of docker.io/library/debian
  # - install gosu from apt instead of pulling docker.io/tianon/gosu
  perl -0pi -e 's|FROM tianon/gosu:[^\n]+ AS gosu_source|FROM scratch AS gosu_source|' "$hermes_build_dir/Dockerfile"
  perl -0pi -e 's|FROM debian:13\.4|FROM mcr.microsoft.com/devcontainers/base:debian-13|' "$hermes_build_dir/Dockerfile"
  perl -0pi -e 's|build-essential curl nodejs|build-essential curl gosu nodejs|' "$hermes_build_dir/Dockerfile"
  perl -0pi -e 's|COPY --from=gosu_source /gosu /usr/local/bin/\n||' "$hermes_build_dir/Dockerfile"
  perl -0pi -e 's|(COPY --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/\n)|$1RUN ln -sf /usr/sbin/gosu /usr/local/bin/gosu \&\& chmod 0755 /usr/sbin/gosu /usr/local/bin/uv /usr/local/bin/uvx\n|' "$hermes_build_dir/Dockerfile"

  az acr build \
    --registry "$ACR_NAME" \
    --image "hermes-agent:$HERMES_IMAGE_TAG" \
    "$hermes_build_dir"

  rm -rf "$hermes_build_dir"
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
  --storage-name hermes-home \
  --access-mode ReadWrite \
  --azure-file-account-name "$STORAGE_ACCOUNT" \
  --azure-file-account-key "$storage_key" \
  --azure-file-share-name "$FILE_SHARE" \
  --output none

az storage file delete \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$FILE_SHARE" \
  --path config.yaml \
  --output none 2>/dev/null || true

az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$FILE_SHARE" \
  --source "$repo_root/config/config.yaml" \
  --path config.yaml \
  --output none

az storage file delete \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$FILE_SHARE" \
  --path SOUL.md \
  --output none 2>/dev/null || true

az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$FILE_SHARE" \
  --source "$repo_root/config/SOUL.md" \
  --path SOUL.md \
  --output none

ACR_LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)"
CONTAINERAPP_ENV_ID="$(
  az containerapp env show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINERAPP_ENV" \
    --query id \
    --output tsv
)"

tmp_dir="$repo_root/.azure-tmp"
mkdir -p "$tmp_dir"
tmp_yaml="$tmp_dir/containerapp.yaml"
GOOGLE_CLIENT_SECRET_B64="$(
  encode_secret_file "${GOOGLE_CLIENT_SECRET_FILE:-$repo_root/.secrets/google-workspace/google_client_secret.json}"
)"
GOOGLE_TOKEN_B64="$(
  encode_secret_file "${GOOGLE_TOKEN_FILE:-$repo_root/.secrets/google-workspace/google_token.json}"
)"
HERMES_CONFIG_DIGEST="$(
  {
    shasum -a 256 "$repo_root/config/config.yaml" "$repo_root/config/SOUL.md"
    printf '%s' "$GOOGLE_CLIENT_SECRET_B64" | shasum -a 256
    printf '%s' "$GOOGLE_TOKEN_B64" | shasum -a 256
  } | shasum -a 256 | awk '{print $1}'
)"
export ACR_LOGIN_SERVER ACR_PULL_ID CONTAINERAPP_ENV_ID HERMES_IMAGE_TAG HERMES_MODEL HERMES_TAIL_FILE_LOGS HERMES_CONFIG_DIGEST
export AZURE_FOUNDRY_API_KEY AZURE_FOUNDRY_BASE_URL
export SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS
export SLACK_HOME_CHANNEL SLACK_HOME_CHANNEL_NAME
export GOOGLE_CLIENT_SECRET_B64 GOOGLE_TOKEN_B64
export COMPOSIO_API_KEY
envsubst '$ACR_LOGIN_SERVER $ACR_PULL_ID $CONTAINERAPP_ENV_ID $HERMES_IMAGE_TAG $HERMES_MODEL $HERMES_TAIL_FILE_LOGS $HERMES_CONFIG_DIGEST $AZURE_FOUNDRY_API_KEY $AZURE_FOUNDRY_BASE_URL $SLACK_BOT_TOKEN $SLACK_APP_TOKEN $SLACK_ALLOWED_USERS $SLACK_HOME_CHANNEL $SLACK_HOME_CHANNEL_NAME $GOOGLE_CLIENT_SECRET_B64 $GOOGLE_TOKEN_B64 $COMPOSIO_API_KEY' \
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
    --image "$ACR_LOGIN_SERVER/hermes-agent:$HERMES_IMAGE_TAG" \
    --output none
fi

echo "Azure deployment finished."
echo "Logs: az containerapp logs show -g $RESOURCE_GROUP -n $CONTAINERAPP_NAME --follow"
