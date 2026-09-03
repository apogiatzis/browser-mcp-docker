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

## Container image (GHCR)

Prebuilt multi-arch images (`linux/amd64`, `linux/arm64`) are published to the
GitHub Container Registry by CI:

```bash
docker pull ghcr.io/apogiatzis/browser-mcp-docker:latest
# or a specific MCP release:
docker pull ghcr.io/apogiatzis/browser-mcp-docker:mcp-0.0.80
```

Tags: `latest` (default branch), `sha-<commit>`, `v<semver>` (on git tags), and
`mcp-<version>` (the resolved `@playwright/mcp` version baked in).

## Build

```bash
docker build -t browser-cdp-mcp:latest .

# Reproducible production build — pin both versions:
docker build \
  --build-arg MCP_VERSION=0.0.80 \
  --build-arg CHROMIUM_VERSION=140.0.7339.185-1~deb12u1 \
  -t browser-cdp-mcp:1.0.0 .
```

### Build args

| Arg                | Default    | Description                                                        |
| ------------------ | ---------- | ------------------------------------------------------------------ |
| `MCP_VERSION`      | `latest`   | `@playwright/mcp` npm version. CI resolves `latest` to a concrete version. |
| `CHROMIUM_VERSION` | *(empty)*  | Exact Debian `chromium` apt version to pin; empty = newest in the suite. |
| `NODE_VERSION`     | `22`       | Node base image tag.                                               |

## CI / auto-update

- **`.github/workflows/build.yml`** — builds and pushes to GHCR on pushes to
  `main`, on `v*` tags, and on manual dispatch (with `mcp_version` /
  `chromium_version` inputs). It is also reusable via `workflow_call`. The build
  is verified post-push by running `chromium --version` and `playwright-mcp
  --version`, recorded in the job summary.
- **`.github/workflows/scheduled-update.yml`** — runs weekly (and on demand),
  calling the build workflow with `mcp_version: latest` so the image tracks the
  newest MCP release and picks up Chromium security updates from Debian on every
  rebuild. Pin a version via workflow-dispatch inputs to override.

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
  ghcr.io/apogiatzis/browser-mcp-docker:latest
```

> Do **not** add `--init` — the image already runs `tini` as its init process.

Or with Compose:

```bash
docker compose up -d --build
docker compose ps          # STATUS should be "healthy"
docker compose logs -f
```

### Accessing apps running on the host

With the default bridge network, `localhost` inside the container is the
container itself — the browser **cannot** reach apps you're running on the host
(e.g. `http://localhost:3000`), including other containers' published ports.

The catch with agents: they don't know they're in a container, so they navigate
to `localhost:<port>` and it silently fails. You want that to just work without
teaching every agent a special hostname.

#### Recommended: transparent `localhost` remap (`MAP_LOCALHOST_TO_HOST`)

Set `MAP_LOCALHOST_TO_HOST=true`. This passes Chromium
`--host-resolver-rules="MAP localhost host.docker.internal"`, so the browser
resolves the `localhost` hostname to the Docker host — for **any port**, with no
port list to maintain. Agents keep typing `localhost:<port>` and reach host apps
unchanged. It needs **no extra privileges**, so the hardened defaults (non-root,
read-only, all caps dropped) stay intact.

```bash
docker run -d --name browser-mcp \
  --shm-size=1g --read-only --tmpfs /tmp:size=512m,mode=1777 \
  --security-opt no-new-privileges:true --cap-drop ALL \
  --add-host=host.docker.internal:host-gateway \
  -e MAP_LOCALHOST_TO_HOST=true \
  -p 8931:8931 ghcr.io/apogiatzis/browser-mcp-docker:latest
```

The bundled `docker-compose.yml` already wires the `extra_hosts` mapping; just
flip `MAP_LOCALHOST_TO_HOST` to `"true"`. On Docker Desktop the
`host.docker.internal` name resolves automatically; the `--add-host` /
`extra_hosts` line makes it work on Linux too.

> **Limitation:** only the `localhost` *hostname* is remapped. A literal
> `http://127.0.0.1:<port>` bypasses Chromium's resolver and is **not** redirected
> — use the `localhost` name. If you must cover literal IPs as well, use host
> networking (below), or a NAT redirect (see *Full loopback redirect*).

#### Alternative: host networking (Linux only)

Share the host's network namespace so the browser hits `localhost:<port>`
directly — covers literal `127.0.0.1` too. Linux only (on Docker Desktop for
Mac/Windows, `--network host` binds the VM, not your machine).

```bash
docker run -d --name browser-mcp --network host \
  --shm-size=1g --read-only --tmpfs /tmp:size=512m,mode=1777 \
  --security-opt no-new-privileges:true --cap-drop ALL \
  ghcr.io/apogiatzis/browser-mcp-docker:latest
```

> With `--network host`, `-p` port mappings are ignored — the MCP server binds
> directly to the host on `8931` (and `9223` if `EXPOSE_CDP=true`). Only use this
> on a trusted host, and consider setting `MCP_HOST=127.0.0.1` to keep the MCP
> port off external interfaces. For Compose, use `network_mode: host` and drop the
> `ports:` block.

#### Full loopback redirect (advanced, breaks the hardened defaults)

If you need every loopback port — including literal `127.0.0.1` — remapped to the
host on Docker Desktop, run a NAT rule inside the container that DNATs loopback
TCP to `host.docker.internal`, excluding the container's own ports (`8931`,
`9222`, `9223`). This requires running as **root** with **`CAP_NET_ADMIN`** and
`net.ipv4.conf.all.route_localnet=1`, which undoes the non-root / dropped-caps
hardening this image ships with — so it is **not** built in. Prefer
`MAP_LOCALHOST_TO_HOST` unless you specifically need literal-IP coverage.

## Connect an agent

The MCP server is reachable at:

| Transport        | URL                          |
| ---------------- | ---------------------------- |
| Streamable HTTP  | `http://<host>:8931/mcp`     |
| SSE (legacy)     | `http://<host>:8931/sse`     |

### Add to your agent

Replace `localhost` with the container/host address if the agent runs elsewhere.

**Claude Code (CLI)**

```bash
claude mcp add --transport http browser http://localhost:8931/mcp
# or SSE:  claude mcp add --transport sse browser http://localhost:8931/sse
claude mcp list
```

**Claude Desktop** — `claude_desktop_config.json` (Settings → Developer → Edit
Config). Stable builds connect to remote servers through the `mcp-remote` bridge:

```json
{
  "mcpServers": {
    "browser": { "command": "npx", "args": ["-y", "mcp-remote", "http://localhost:8931/mcp"] }
  }
}
```

**Cursor** — `~/.cursor/mcp.json` (global) or `.cursor/mcp.json` (project):

```json
{
  "mcpServers": {
    "browser": { "url": "http://localhost:8931/mcp" }
  }
}
```

**VS Code (GitHub Copilot, agent mode)** — CLI or `.vscode/mcp.json`:

```bash
code --add-mcp '{"name":"browser","type":"http","url":"http://localhost:8931/mcp"}'
```

```json
{
  "servers": {
    "browser": { "type": "http", "url": "http://localhost:8931/mcp" }
  }
}
```

**Windsurf** — `~/.codeium/windsurf/mcp_config.json` (uses the SSE endpoint):

```json
{
  "mcpServers": {
    "browser": { "serverUrl": "http://localhost:8931/sse" }
  }
}
```

**Cline / Roo Code / other stdio-only clients** — bridge HTTP to stdio with
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote):

```json
{
  "mcpServers": {
    "browser": { "command": "npx", "args": ["-y", "mcp-remote", "http://localhost:8931/mcp"] }
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
  ghcr.io/apogiatzis/browser-mcp-docker:latest

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
| `MAP_LOCALHOST_TO_HOST` | `false`    | If `true`, remap the browser's `localhost` to the Docker host (any port). Needs `host.docker.internal` to resolve. |
| `HOST_INTERNAL_NAME` | `host.docker.internal` | Hostname `localhost` is remapped to when the above is on. |
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
