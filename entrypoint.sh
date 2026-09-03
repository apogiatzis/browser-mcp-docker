#!/usr/bin/env bash
#
# Builds the runtime supervisor config in /tmp (works with a read-only rootfs)
# and hands off to supervisord as PID 1's child under tini.
set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"
MCP_PORT="${MCP_PORT:-8931}"
MCP_HOST="${MCP_HOST:-0.0.0.0}"
MCP_ALLOWED_HOSTS="${MCP_ALLOWED_HOSTS:-*}"
CHROME_BIN="${CHROME_BIN:-/usr/bin/chromium}"
WINDOW_SIZE="${WINDOW_SIZE:-1280,720}"
EXPOSE_CDP="${EXPOSE_CDP:-false}"
CDP_PROXY_PORT="${CDP_PROXY_PORT:-9223}"
MAP_LOCALHOST_TO_HOST="${MAP_LOCALHOST_TO_HOST:-false}"
HOST_INTERNAL_NAME="${HOST_INTERNAL_NAME:-host.docker.internal}"

# Remap the browser's `localhost` to the Docker host so agents can reach host apps
# by typing localhost:<port> unchanged. Only the `localhost` *hostname* is remapped
# (any port is preserved); a literal 127.0.0.1 in a URL bypasses Chromium's resolver
# and is not affected. Kept empty unless opted in, so the default posture is untouched.
CHROME_HOST_RESOLVER=""
if [ "${MAP_LOCALHOST_TO_HOST}" = "true" ]; then
    if ! getent hosts "${HOST_INTERNAL_NAME}" >/dev/null 2>&1; then
        echo "[entrypoint] WARNING: MAP_LOCALHOST_TO_HOST=true but '${HOST_INTERNAL_NAME}' does not resolve."
        echo "[entrypoint]          On Docker Desktop it is automatic; on Linux add"
        echo "[entrypoint]          --add-host=${HOST_INTERNAL_NAME}:host-gateway (compose: extra_hosts)."
    fi
    CHROME_HOST_RESOLVER="--host-resolver-rules=\"MAP localhost ${HOST_INTERNAL_NAME}\""
    echo "[entrypoint] localhost remap ENABLED: browser 'localhost' -> ${HOST_INTERNAL_NAME} (any port)"
fi

# Exported so supervisord can expand them via %(ENV_x)s.
export CDP_PORT MCP_PORT MCP_HOST MCP_ALLOWED_HOSTS CHROME_BIN WINDOW_SIZE CHROME_HOST_RESOLVER

# Create writable HOME/XDG/output dirs on the /tmp tmpfs (read-only rootfs).
mkdir -p \
    "${XDG_CACHE_HOME:-/tmp/app-home/.cache}" \
    "${XDG_CONFIG_HOME:-/tmp/app-home/.config}" \
    "${XDG_DATA_HOME:-/tmp/app-home/.local/share}" \
    "${MCP_OUTPUT_DIR:-/tmp/mcp-output}" \
    /tmp/chrome-user-data
export MCP_OUTPUT_DIR="${MCP_OUTPUT_DIR:-/tmp/mcp-output}"

RUNTIME_CONF="/tmp/supervisord.runtime.conf"
cp /etc/supervisor/supervisord.conf "${RUNTIME_CONF}"

if [ "${EXPOSE_CDP}" = "true" ]; then
    cat >> "${RUNTIME_CONF}" <<EOF

[program:cdp-proxy]
priority=30
command=socat TCP-LISTEN:${CDP_PROXY_PORT},fork,reuseaddr TCP:127.0.0.1:${CDP_PORT}
autorestart=true
startretries=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
    echo "[entrypoint] CDP proxy ENABLED: 0.0.0.0:${CDP_PROXY_PORT} -> 127.0.0.1:${CDP_PORT}"
    echo "[entrypoint] WARNING: the CDP endpoint is UNAUTHENTICATED and grants full control"
    echo "[entrypoint]          of the browser. Only expose it on a trusted/private network."
fi

echo "[entrypoint] starting: chromium (CDP :${CDP_PORT} loopback) + MCP (http://${MCP_HOST}:${MCP_PORT})"
exec supervisord -c "${RUNTIME_CONF}" -n
