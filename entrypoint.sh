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

# Exported so supervisord can expand them via %(ENV_x)s.
export CDP_PORT MCP_PORT MCP_HOST MCP_ALLOWED_HOSTS CHROME_BIN WINDOW_SIZE

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
