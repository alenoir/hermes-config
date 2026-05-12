#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
./scripts/init-local.sh

docker compose build openclaw
docker compose run --rm --entrypoint openclaw openclaw models auth login --provider openai-codex
docker compose run --rm --entrypoint openclaw openclaw models auth list --provider openai-codex

echo
echo "OpenAI Codex OAuth profile stored under ./data."
echo "Deploy it to Azure with:"
echo "OPENCLAW_UPLOAD_LOCAL_STATE=true OPENCLAW_SKIP_IMAGE_BUILD=true ./scripts/deploy-azure.sh"
