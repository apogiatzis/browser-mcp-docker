#!/usr/bin/env bash
#
# Healthy when: (1) Chromium's CDP endpoint answers, and (2) the MCP port accepts
# TCP connections. Uses only tools present in the image (curl + bash /dev/tcp).
set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"
MCP_PORT="${MCP_PORT:-8931}"

# 1. Chromium DevTools is up and reports a version.
curl -fsS --max-time 3 "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null

# 2. MCP server is accepting connections.
timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${MCP_PORT}" 2>/dev/null

echo "ok"
