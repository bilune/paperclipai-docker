# =============================================================================
# Paperclip - Multi-stage Docker build
# Builds from source: https://github.com/paperclipai/paperclip
# =============================================================================

# --- Stage 1: Base image with system dependencies ---
FROM node:lts-trixie-slim AS base

ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    gosu \
    curl \
    git \
    wget \
    ripgrep \
    python3 \
  # Install GitHub CLI
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -nv -O/etc/apt/keyrings/githubcli-archive-keyring.gpg \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Match host UID/GID for volume permissions
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

# --- Stage 2: Clone repo and install dependencies ---
FROM base AS deps
WORKDIR /app

# Aerolab: pin Paperclip to the commit just BEFORE the company-scoped-plugin
# security migration (PAP-2394). Upstream master ships that migration only
# half-done, which fail-closes plugin secret refs (#5429, 2026-05-09) and the
# plugin runtime invocation scope (#6547, 2026-05-22), breaking this plugin's
# secret resolution + host calls. This commit (parent of #5429) predates all of
# it, so plugin secret-refs and host services work natively — no source patches.
# Revisit/bump once upstream finishes PAP-2394 (re-enables company-scoped refs).
ARG PAPERCLIP_REF=06e6ee25cd7e3e882b7dda398243c2b0095cd22a
RUN git clone https://github.com/paperclipai/paperclip.git . \
  && git checkout "$PAPERCLIP_REF" \
  && pnpm install --frozen-lockfile

# --- Stage 3: Build all packages ---
FROM deps AS build
WORKDIR /app

# Aerolab: Paperclip only stashes the raw request body for JSON requests, so
# Slack slash-command / interactivity webhooks (urlencoded) fail HMAC signature
# verification. This patch adds a urlencoded parser that also captures the raw
# body. Upstream gap (present on master too); remove if upstream fixes it.
COPY patch-rawbody.cjs /tmp/patch-rawbody.cjs
RUN node /tmp/patch-rawbody.cjs

RUN pnpm --filter @paperclipai/ui build \
  && pnpm --filter @paperclipai/plugin-sdk build \
  && pnpm --filter @paperclipai/server build \
  && test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

# --- Stage 4: Production image ---
FROM base AS production

ARG USER_UID=1000
ARG USER_GID=1000

WORKDIR /app
COPY --chown=node:node --from=build /app /app

# Install global AI agent CLI tools
RUN npm install --global --omit=dev \
    @anthropic-ai/claude-code@latest \
    @openai/codex@latest \
    opencode-ai \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true

VOLUME ["/paperclip"]
EXPOSE 3100

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
