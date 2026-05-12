# OpenClaw Slack Deployment Kit

Config repo for a personal OpenClaw assistant in Slack, deployable on Azure Container Apps.

This repo replaced the archived Hermes setup. Roll back to Hermes with the GitHub release/tag:

```bash
git checkout hermes-v0.1.0
```

## Target

```txt
Slack
  -> Azure Container Apps
  -> OpenClaw Gateway
  -> Azure Files persistent OpenClaw state
  -> OpenAI Codex OAuth / ChatGPT Pro
```

OpenClaw runs from `/root/.openclaw` on local container storage. Azure Files is mounted separately and used as the persistence store copied into the runtime directory at startup and synced back periodically. This avoids Azure Files symlink issues with OpenClaw plugin skills while keeping OAuth profiles and state recoverable across restarts.

The deployment intentionally keeps one replica:

```txt
minReplicas = 1
maxReplicas = 1
```

Socket Mode uses a long-lived Slack WebSocket, so scale-to-zero is not useful here.

## Files

```txt
config/openclaw.json        OpenClaw JSON5 config
Dockerfile                  OpenClaw runtime image
docker-compose.yml          Local run
azure/containerapp.yaml.tpl Azure Container Apps template
scripts/init-local.sh       Prepare local state
scripts/openai-codex-auth.sh Login with ChatGPT/Codex OAuth locally
scripts/deploy-azure.sh     Build and deploy to Azure
scripts/logs-azure.sh       Tail Azure logs
slack-manifest.json         Slack app manifest
```

## Local Setup

```bash
./scripts/init-local.sh
```

Fill `.env`, then:

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

OpenClaw dashboard:

```txt
http://127.0.0.1:18789
```

## OpenAI Codex / ChatGPT Pro Auth

OpenClaw can use OpenAI Codex OAuth for ChatGPT/Codex subscription auth.

Run:

```bash
./scripts/openai-codex-auth.sh
```

Complete the browser login. In headless flows, paste the final redirect URL when prompted.

The OAuth profile is stored under `./data`, which is ignored by git.

To upload that local OpenClaw state to Azure:

```bash
OPENCLAW_UPLOAD_LOCAL_STATE=true OPENCLAW_SKIP_IMAGE_BUILD=true ./scripts/deploy-azure.sh
```

## Slack Setup

Import `slack-manifest.json` into the existing Slack app, then reinstall the app to the workspace.

Required tokens:

```env
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_ALLOWED_USERS=U06JF46Q57F
```

Invite the bot to channels where it should answer:

```txt
/invite @Dwight Schrute
```

Channel messages are mention-gated by default. Threads continue through OpenClaw's Slack thread session handling.

Useful OpenClaw chat commands:

```txt
/status
/think high
/verbose on
/trace on
/usage full
/restart
/activation mention
```

## Azure Deploy

The defaults reuse the existing Azure resource names so the old Hermes Container App is replaced by OpenClaw instead of running two Slack Socket Mode clients.

Required `.env` values:

```env
RESOURCE_GROUP=rg-Urbanquest
LOCATION=swedencentral
CONTAINERAPP_ENV=hermes-env
CONTAINERAPP_NAME=hermes-agent
ACR_NAME=urbanquesthermesacr
ACR_PULL_IDENTITY=hermes-acr-pull
STORAGE_ACCOUNT=urbanquesthermesst
FILE_SHARE=hermes

SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_ALLOWED_USERS=U06JF46Q57F
```

Deploy:

```bash
./scripts/deploy-azure.sh
```

Tail logs:

```bash
./scripts/logs-azure.sh
```

## Model Strategy

The default OpenClaw config uses:

```txt
primary:   openai/gpt-5.5
fallbacks: openai/gpt-5.4, openai/gpt-5.4-mini
```

The Slack command `/think high` can raise effort for one session. The config also enables full local tool access inside the container for Antoine's Slack user.

## Notes

This deployment gives the agent shell/filesystem access inside the container, not to the Azure host. For safer multi-user setups, enable OpenClaw sandboxing later. For this personal Slack assistant, the config favors capability and debuggability over strict sandbox isolation.
