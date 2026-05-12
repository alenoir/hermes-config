# Hermes Slack Deployment Kit

Config repo for a simple Hermes personal assistant on Slack.

Target MVP:
- Azure Container Apps
- Slack Socket Mode
- Azure OpenAI / Azure AI Foundry
- local Hermes state inside the running Container App replica
- MCP exposed later with `hermes mcp serve`

This repo intentionally avoids AKS, Neon, Upstash, multi-agent automation, and GitHub automation for the first version.

## Architecture

```txt
Slack
  -> Azure Container Apps
  -> Hermes gateway
  -> /opt/data local container state
  -> Azure Files bootstrap config
  -> Azure OpenAI / Azure AI Foundry
```

Hermes stores config, memories, sessions, and local SQLite state under `HERMES_HOME`. In this deployment `HERMES_HOME=/opt/data`.

On Azure, `/opt/data` is an `EmptyDir` local volume. Azure Files is only used to bootstrap `config.yaml` and `SOUL.md`; SQLite on Azure Files can hit SMB locking and permission issues. This means the MVP is simple and stable, but Hermes state is not durable across replica replacement. For durable memory, move the memory layer to Postgres/Neon or another service instead of putting SQLite on Azure Files.

Because this MVP uses local file-backed state, keep Azure Container Apps at:

```txt
minReplicas = 1
maxReplicas = 1
```

`minReplicas=1` also matters because Slack Socket Mode is a long-lived WebSocket connection. A scale-to-zero app cannot receive Slack events until something wakes it, and Socket Mode has no public HTTP ingress to do that.

## Files

```txt
config/config.yaml          Hermes base config
config/SOUL.md              Assistant identity
docker-compose.yml          Local run
azure/containerapp.yaml.tpl Azure Container Apps template
scripts/init-local.sh       Prepare local clone/state
scripts/deploy-azure.sh     Build Hermes and deploy to Azure
scripts/logs-azure.sh       Tail Azure logs
```

## Local Run

```bash
./scripts/init-local.sh
```

Fill `.env`, then:

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

The local persistent state is in `./data`, which maps to `/opt/data` in the container.

## Slack Setup

Use the Hermes-generated manifest when possible:

```bash
docker compose run --rm hermes slack manifest --write
```

Then copy the generated manifest from `data/slack-manifest.json` into Slack.

Required runtime values:

```env
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_ALLOWED_USERS=U...
```

Invite the bot to any channel where it should respond:

```txt
/invite @Hermes Agent
```

## Azure Deploy

Export deployment settings:

```bash
export ACR_NAME=hermesregistry123
export STORAGE_ACCOUNT=hermesstate123
export FILE_SHARE=hermes

# Optional if using the existing Urbanquest AI resource:
# AZURE_AI_RESOURCE_GROUP=rg-Urbanquest
# AZURE_AI_RESOURCE_NAME=urbanquest-resource
# HERMES_MODEL=gpt-5.4-mini
#
# Otherwise provide these explicitly:
# export AZURE_FOUNDRY_API_KEY=...
# export AZURE_FOUNDRY_BASE_URL=https://<resource>.cognitiveservices.azure.com/openai/v1

export SLACK_BOT_TOKEN=xoxb-...
export SLACK_APP_TOKEN=xapp-...
export SLACK_ALLOWED_USERS=U...
```

Optional names:

```bash
export RESOURCE_GROUP=rg-Urbanquest
export LOCATION=swedencentral
export CONTAINERAPP_ENV=hermes-env
export CONTAINERAPP_NAME=hermes-agent
```

Deploy:

```bash
./scripts/deploy-azure.sh
```

Tail logs:

```bash
./scripts/logs-azure.sh
```

## Google Workspace

For Gmail and Calendar access, use Hermes' bundled `google-workspace` skill. Credentials stay in `.secrets/` locally and are deployed to Azure Container Apps as secrets.

Create a Google Cloud OAuth **Desktop app** credential, download the client secret JSON, then run:

```bash
./scripts/google-workspace-auth.sh client-secret ~/Downloads/client_secret_....json
./scripts/google-workspace-auth.sh auth-url
./scripts/google-workspace-auth.sh auth-code "PASTE_THE_REDIRECT_URL_HERE"
./scripts/google-workspace-auth.sh check
HERMES_SKIP_IMAGE_BUILD=true ./scripts/deploy-azure.sh
```

The current Hermes setup script requests the full Google Workspace scope set in one OAuth flow.

To redeploy only the Azure resources/YAML after the image already exists:

```bash
HERMES_SKIP_IMAGE_BUILD=true ./scripts/deploy-azure.sh
```

## MCP Later

For Claude Code or another MCP client, run Hermes MCP against the same `HERMES_HOME`:

```bash
hermes mcp serve
```

Client config shape:

```json
{
  "mcpServers": {
    "hermes": {
      "command": "hermes",
      "args": ["mcp", "serve"]
    }
  }
}
```

For a cloud MCP endpoint, add a second Container App later. Do not run multiple writers against the same local SQLite state; use a real external store before doing that.
