FROM node:24-bookworm

ARG OPENCLAW_VERSION=2026.5.7

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    python3 \
    python3-pip \
    ripgrep \
    build-essential \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g "openclaw@${OPENCLAW_VERSION}" mcp-remote

ENV NODE_ENV=production \
    OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json \
    OPENCLAW_STATE_DIR=/root/.openclaw

COPY config/openclaw.json /app/config/openclaw.json

WORKDIR /workspace
EXPOSE 18789

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:18789/healthz || exit 1

CMD ["openclaw", "gateway", "--port", "18789", "--verbose"]
