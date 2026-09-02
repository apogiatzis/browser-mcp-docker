# browser-cdp-mcp

Production-grade Docker image that runs a headless Chromium browser and exposes a
**CDP-backed MCP server** over HTTP/SSE for AI agents.

```
┌─────────────────────────── container ───────────────────────────┐
│                                                                  │
│   Chromium (headless, --remote-debugging-port on 127.0.0.1)      │
│        ▲                                                         │
│        │ CDP (loopback only, unauthenticated)                    │
│        │                                                         │
│   Playwright MCP server ──── HTTP / SSE ────►  :8931  ───────────┼──► AI agent
│                                                                  │
│   [optional] socat proxy ─── raw CDP ───────►  :9223  (debug)    │
│                                                                  │
│   supervisord (process mgmt) · tini (PID 1, zombie reaping)      │
└──────────────────────────────────────────────────────────────────┘
```

Chromium's DevTools endpoint is **unauthenticated and equivalent to code execution**
on the browser host, so it is bound to `127.0.0.1` and never published by default.
Agents talk to the MCP server; the raw CDP port is only reachable via an opt-in proxy.

## Why this design

- **MCP as the agent surface** — [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp)
  is a mature, well-maintained server with a rich accessibility-tree toolset and
  native HTTP/SSE transports, connected to the running browser via `--cdp-endpoint`.
- **Single long-lived browser** — Chromium is a supervised process, so the CDP
  target (and any warmed-up state) survives across agent sessions and MCP restarts.
- **Hardened by default** — non-root, read-only rootfs, all Linux capabilities
  dropped, `no-new-privileges`, healthchecked.

## Build

```bash
docker build -t browser-cdp-mcp:latest .

# Reproducible production build — pin the MCP server version:
docker build --build-arg MCP_VERSION=0.0.41 -t browser-cdp-mcp:1.0.0 .
```

## Run

Recommended hardened invocation:

```bash
docker run -d --name browser-mcp \
  --shm-size=1g \
  --read-only --tmpfs /tmp:size=512m,mode=1777 \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --memory 2g --cpus 2 \
  -p 8931:8931 \
  browser-cdp-mcp:latest
```

> Do **not** add `--init` — the image already runs `tini` as its init process.

Or with Compose:

```bash
docker compose up -d --build
docker compose ps          # STATUS should be "healthy"
docker compose logs -f
```

## Connect an agent

The MCP server is reachable at:

| Transport        | URL                          |
| ---------------- | ---------------------------- |
| Streamable HTTP  | `http://<host>:8931/mcp`     |
| SSE (legacy)     | `http://<host>:8931/sse`     |

Example client config (Claude Desktop / Cursor / any MCP client):

```json
{
  "mcpServers": {
    "browser": {
      "type": "http",
      "url": "http://localhost:8931/mcp"
    }
  }
}
```

Quick smoke test (streamable HTTP initialize):

```bash
curl -s -X POST http://localhost:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
       "params":{"protocolVersion":"2024-11-05","capabilities":{},
                 "clientInfo":{"name":"cli","version":"0"}}}'
```

## Exposing raw CDP (optional, debugging)

Set `EXPOSE_CDP=true` and publish port `9223`. A `socat` proxy forwards
`0.0.0.0:9223 → 127.0.0.1:9222` (Chromium refuses to bind DevTools to a
non-loopback address itself).

```bash
docker run -d --name browser-mcp \
  --shm-size=1g -e EXPOSE_CDP=true \
  -p 8931:8931 -p 9223:9223 \
  browser-cdp-mcp:latest

curl http://localhost:9223/json/version
```

> ⚠️ **Security:** the CDP endpoint has no authentication and grants full control
> of the browser. Only enable this on a trusted/private network, and put an
> authenticating reverse proxy in front of it if it must cross a trust boundary.
>
> **Note:** Chromium reports `webSocketDebuggerUrl` with the loopback host it was
> bound to. Remote CDP clients may need to rewrite the ws host to the container's
> published address.

## Configuration

| Env var             | Default        | Description                                            |
| ------------------- | -------------- | ------------------------------------------------------ |
| `MCP_HOST`          | `0.0.0.0`      | Interface the MCP server binds to.                     |
| `MCP_PORT`          | `8931`         | MCP HTTP/SSE port.                                     |
| `MCP_ALLOWED_HOSTS` | `*`            | Host-header allowlist (`*` disables the check).        |
| `CDP_PORT`          | `9222`         | Chromium DevTools port (loopback only).                |
| `EXPOSE_CDP`        | `false`        | If `true`, start the CDP proxy on `CDP_PROXY_PORT`.    |
| `CDP_PROXY_PORT`    | `9223`         | Published port for the CDP proxy.                      |
| `WINDOW_SIZE`       | `1280,720`     | Chromium viewport / window size.                       |
| `MCP_OUTPUT_DIR`    | `/tmp/mcp-output` | Where the MCP server writes snapshots/traces.       |

## Operations

- **Health:** `HEALTHCHECK` verifies the CDP endpoint answers **and** the MCP
  port accepts connections. Use it as your orchestrator readiness gate.
- **Logs:** Chromium, the MCP server, and the CDP proxy all log to the container's
  stdout/stderr (`docker logs`). dbus / gcm / crashpad errors from Chromium are
  benign headless-container noise.
- **Memory:** headless Chromium is memory-hungry and uses `/dev/shm`. Keep
  `--shm-size=1g` (the image also passes `--disable-dev-shm-usage` as a fallback).
- **Scaling:** run one container per concurrent browser workload and load-balance
  the MCP port; a single Chromium instance is not meant for heavy parallel isolation.

## Notes & alternatives

- Chromium runs with `--no-sandbox`; the container (non-root, dropped caps,
  read-only rootfs, `no-new-privileges`) is the isolation boundary. To keep
  Chromium's own sandbox instead, drop `--no-sandbox` from `supervisord.conf` and
  run with a Chromium seccomp profile
  (`--security-opt seccomp=chrome.json`).
- To use the official Google **`chrome-devtools-mcp`** instead of Playwright MCP,
  swap the `[program:mcp]` command in `supervisord.conf` to run it against
  `--browser-url http://127.0.0.1:9222` (bridge its stdio transport to HTTP with a
  gateway if network exposure is required).
```
