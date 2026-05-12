#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hermes_source_dir="$repo_root/.build/hermes-agent"
google_home="$repo_root/.secrets/google-workspace"
setup_script="$hermes_source_dir/skills/productivity/google-workspace/scripts/setup.py"

if [[ ! -d "$hermes_source_dir/.git" ]]; then
  mkdir -p "$(dirname "$hermes_source_dir")"
  git clone https://github.com/NousResearch/hermes-agent.git "$hermes_source_dir"
fi

mkdir -p "$google_home"

run_setup() {
  HERMES_HOME="$google_home" uv run --project "$hermes_source_dir" python "$setup_script" "$@"
}

usage() {
  cat <<'USAGE'
Usage:
  scripts/google-workspace-auth.sh check
  scripts/google-workspace-auth.sh client-secret /path/to/client_secret.json
  scripts/google-workspace-auth.sh auth-url
  scripts/google-workspace-auth.sh auth-code "http://localhost:1/?code=..."
  scripts/google-workspace-auth.sh revoke

Recommended MVP:
  scripts/google-workspace-auth.sh client-secret ~/Downloads/client_secret_....json
  scripts/google-workspace-auth.sh auth-url
  scripts/google-workspace-auth.sh auth-code "PASTE_REDIRECT_URL_HERE"
  scripts/google-workspace-auth.sh check

Generated files:
  .secrets/google-workspace/google_client_secret.json
  .secrets/google-workspace/google_token.json
USAGE
}

cmd="${1:-}"
case "$cmd" in
  check)
    run_setup --check
    ;;
  client-secret)
    if [[ -z "${2:-}" ]]; then
      usage >&2
      exit 2
    fi
    run_setup --client-secret "$2"
    ;;
  auth-url)
    run_setup --auth-url
    ;;
  auth-code)
    if [[ -z "${2:-}" ]]; then
      usage >&2
      exit 2
    fi
    run_setup --auth-code "$2"
    ;;
  revoke)
    run_setup --revoke
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
