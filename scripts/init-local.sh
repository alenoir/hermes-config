#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_root/.build/hermes-agent"
data_dir="$repo_root/data"

mkdir -p "$data_dir"

if [[ ! -d "$build_dir/.git" ]]; then
  mkdir -p "$(dirname "$build_dir")"
  git clone https://github.com/NousResearch/hermes-agent.git "$build_dir"
fi

if [[ ! -f "$data_dir/config.yaml" ]]; then
  cp "$repo_root/config/config.yaml" "$data_dir/config.yaml"
fi

if [[ ! -f "$data_dir/SOUL.md" ]]; then
  cp "$repo_root/config/SOUL.md" "$data_dir/SOUL.md"
fi

if [[ ! -f "$repo_root/.env" ]]; then
  cp "$repo_root/.env.example" "$repo_root/.env"
  echo "Created .env from .env.example. Fill the secrets before starting Docker."
fi

echo "Local Hermes deployment files are ready."
echo "Next: docker compose build && docker compose up -d"
