#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_dir="$repo_root/data"

mkdir -p "$data_dir"

if [[ ! -f "$data_dir/openclaw.json" ]]; then
  cp "$repo_root/config/openclaw.json" "$data_dir/openclaw.json"
fi

if [[ ! -f "$repo_root/.env" ]]; then
  cp "$repo_root/.env.example" "$repo_root/.env"
  echo "Created .env from .env.example. Fill the secrets before starting Docker."
fi

echo "Local OpenClaw deployment files are ready."
echo "Next: docker compose build && docker compose up -d"
