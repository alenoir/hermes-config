#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-Urbanquest}"
CONTAINERAPP_NAME="${CONTAINERAPP_NAME:-hermes-agent}"

az containerapp logs show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINERAPP_NAME" \
  --follow
