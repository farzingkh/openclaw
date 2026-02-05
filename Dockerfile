FROM node:22-bookworm

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R node:node /app

# Create entrypoint script that fixes volume permissions and configures trustedProxies
RUN echo '#!/bin/bash\n\
if [ -d "/data" ]; then\n\
  chown -R node:node /data 2>/dev/null || true\n\
fi\n\
if [ -d "/mnt/data" ]; then\n\
  chown -R node:node /mnt/data 2>/dev/null || true\n\
fi\n\
# Configure trustedProxies for Railway/cloud proxies (100.64.0.0/10 is CGNAT range used by Railway)\n\
if [ -n "$OPENCLAW_TRUSTED_PROXIES" ]; then\n\
  gosu node node /app/dist/index.js config set gateway.trustedProxies "$OPENCLAW_TRUSTED_PROXIES" 2>/dev/null || true\n\
else\n\
  gosu node node /app/dist/index.js config set gateway.trustedProxies "[\"100.64.0.0/10\", \"127.0.0.1\"]" 2>/dev/null || true\n\
fi\n\
exec gosu node "$@"' > /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

# Install gosu for dropping privileges
RUN apt-get update && apt-get install -y --no-install-recommends gosu && \
    rm -rf /var/lib/apt/lists/*

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","dist/index.js","gateway","--allow-unconfigured","--bind","lan"]
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "dist/index.js", "gateway", "--allow-unconfigured", "--bind", "lan"]
