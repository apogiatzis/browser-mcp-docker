# syntax=docker/dockerfile:1.7
#
# Production browser-in-a-container with a CDP-backed MCP server for AI agents.
#
#   Chromium (headless, CDP on loopback)  <--CDP--  Playwright MCP server  <--HTTP/SSE--  AI agent
#
# Chromium's raw DevTools endpoint is intentionally bound to 127.0.0.1 only. It is
# unauthenticated and equivalent to remote code execution on the browser host, so it
# is never exposed directly. Agents talk to the MCP server; the CDP port can be
# published for debugging via an opt-in socat proxy (EXPOSE_CDP=true).

ARG NODE_VERSION=22

########################################################################
# Single runtime stage (browser + node runtime share the same image).
########################################################################
FROM node:${NODE_VERSION}-bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/apogiatzis/browser-mcp-docker" \
      org.opencontainers.image.description="Headless Chromium + CDP-backed Playwright MCP server for AI agents" \
      org.opencontainers.image.licenses="MIT"

# --- Configurable versions --------------------------------------------------
# MCP server: pin to a validated release for reproducible builds, or leave
#   "latest". CI resolves this to a concrete version at build time.
ARG MCP_VERSION=latest
# Chromium: leave empty to install the newest version in the Debian suite
#   (picks up security updates on every rebuild), or pin an exact apt version
#   string, e.g. --build-arg CHROMIUM_VERSION=140.0.7339.185-1~deb12u1
ARG CHROMIUM_VERSION=

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production \
    # We connect to an already-running Chromium over CDP, so the MCP server must
    # never try to download its own browser binaries at install/run time.
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# ---------------------------------------------------------------------------
# System dependencies: Chromium + its runtime libs (pulled in transitively),
# fonts for correct rendering, and process/health tooling.
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ -n "${CHROMIUM_VERSION}" ]; then CHROMIUM_PKG="chromium=${CHROMIUM_VERSION}"; else CHROMIUM_PKG="chromium"; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "${CHROMIUM_PKG}" \
        ca-certificates \
        fonts-liberation \
        fonts-noto-color-emoji \
        fonts-noto-cjk \
        tini \
        socat \
        supervisor \
        curl \
        procps; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# MCP server. Installed globally; exposes the `playwright-mcp` binary.
# ---------------------------------------------------------------------------
RUN npm install -g @playwright/mcp@${MCP_VERSION} \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# Non-root runtime user.
# ---------------------------------------------------------------------------
RUN groupadd -r app \
    && useradd -r -g app -G audio,video -m -d /home/app app

# Redirect HOME and XDG dirs into /tmp so the image runs on a read-only root
# filesystem (Chromium + Playwright need writable cache/config/data dirs).
ENV HOME=/tmp/app-home \
    XDG_CACHE_HOME=/tmp/app-home/.cache \
    XDG_CONFIG_HOME=/tmp/app-home/.config \
    XDG_DATA_HOME=/tmp/app-home/.local/share \
    MCP_OUTPUT_DIR=/tmp/mcp-output

ENV CHROME_BIN=/usr/bin/chromium \
    CDP_PORT=9222 \
    MCP_PORT=8931 \
    MCP_HOST=0.0.0.0 \
    MCP_ALLOWED_HOSTS=* \
    WINDOW_SIZE=1280,720 \
    EXPOSE_CDP=false \
    CDP_PROXY_PORT=9223

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

USER app
WORKDIR /home/app

# 8931: MCP (HTTP/SSE, for agents).  9223: optional CDP proxy (debug only).
EXPOSE 8931 9223

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# tini reaps zombie processes spawned by Chromium and forwards signals.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
