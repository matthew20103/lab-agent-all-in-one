---
name: add-mcp-server
description: Add a new MCP server to the mcp-hub (Ubuntu server behind Prisma AIRS AI Gateway, nginx bearer-token proxy, GitHub Actions deploy on a self-hosted runner). Use when the user wants to add, host, register, or remove an MCP server in the hub, or asks how the hub/deploy/gateway setup works.
---

# Add an MCP server to the mcp-hub

## Background (don't ask the user for this again)

- **Goal:** one Ubuntu server hosting many MCP servers. Each is reachable only via an nginx proxy that checks a per-server bearer token. The **Prisma AIRS AI Gateway** (MCP Gateway) registers each server with its token and decides which agents may use which tools.
- **Hosts (LAN 192.168.110.0/24):**
  - MCP hub server: `ubuntu-mcp-tools`, `192.168.110.25`, hostname `mcphub.matthewwan.dev` (the LAN DNS may not resolve it; prefer the IP in tests). Proxy on port **8080**.
  - AI Gateway: `192.168.110.161:8788`. Agents call `http://192.168.110.161:8788/<slug>/mcp`.
  - Agent app: `ubuntu-ai-agent-server` (`192.168.110.51`), container `agent-backend-agent-1`.
- **Repo:** local `~/Documents/my-mcp-tools/mcp-hub` (the only git repo; the parent folder is not). Remote `https://github.com/matthew20103/mcp-hub.git` (HTTPS, branch `main`).
- **Deploy:** push to `main` → workflow `.github/workflows/deploy.yml`: `validate` job (GitHub cloud) runs `bash -n` and `docker compose config`, then the `deploy` job on the self-hosted runner (label `mcp-hub`, runs as user `mwan`) rsyncs to `/opt/mcp-hub` and runs `scripts/deploy.sh`.
- **deploy.sh:**
  - Creates any missing `MCP_TOKEN_*` in `~/mcp-secrets/hub.env` (the names come from `proxy/templates`).
  - Fails if a `${HOME}/mcp-secrets/<file>.env` referenced by a server compose file is missing.
  - Runs `docker compose up -d --build --remove-orphans`, then recreates the proxy.
  - Smoke-tests every route: POST without token → must be 401; token + bare `tools/list` → must be 200.
  - Never prints tokens in CI.
- **Secrets:** only on the server, in `/home/mwan/mcp-secrets/` (chmod 700, files chmod 600, owned by `mwan`).
  - `hub.env` holds the `MCP_TOKEN_<NAME>=...` values.
  - `<name>.env` holds a backend's own API keys.
  - Never in Git, GitHub Secrets, or logs. Never read or write `.env*` files locally; permissions block it anyway.
- **The Mac has no Docker.** `docker compose config` can't run locally; CI `validate` checks it.
- **On the server,** run `docker compose` as `mwan` **without sudo** (with sudo, `${HOME}` becomes `/root`).
- **First server:** `openserp` (`@openserp/mcp` 0.1.7, official MCP SDK 1.x, Streamable HTTP, stateless). Google shows captchas to its headless Chrome; Bing and DuckDuckGo work.
- **Second server: `ragflow`** (the knowledge base; RAGFlow `v0.27.2`, guide section 13).
  - Containers: `ragflow-server` (web UI on host `:8081`), `ragflow-es`, `ragflow-mysql`, `ragflow-minio` and `ragflow-redis`, on the internal network `ragflow`.
  - `ragflow-mcp` runs the same image with `entrypoint: python3 /ragflow/mcp/server/server.py`. It is configured by `RAGFLOW_MCP_*` env vars and is stateless.
  - All passwords and the RAGFlow API key are in `~/mcp-secrets/ragflow.env`.
  - Embedding and rerank models come from the AI Gateway and are set in the RAGFlow UI (OpenAI-API-Compatible provider).
    - The gateway's LLM API is `http://192.168.110.161/v1` on port 80. Port 8788 is MCP only.
    - Models: `@google-vertex-sep/text-embedding-005` and `@google-vertex-sep/semantic-ranker-default-004`. Portkey needs the `@<provider-slug>/` prefix.
    - Reranking needs `discoveryengine.rankingConfigs.rank` for SA `portkey-vertex-sa@prod-q6n0rq.iam.gserviceaccount.com`. Use the custom role `projects/prod-q6n0rq/roles/discoveryEngineRanker`; `roles/discoveryengine.user` does NOT include it.
  - Leave out `--enable-adminserver`: the web nginx would expose the admin API, whose default password is `admin`.
- **Third server: `memory`** (per-user agent memory; mem0 v2.2.1, guide section 14, gateway slug `agent-memory`).
  - Containers:
    - `memory-mcp`: our stateless FastMCP wrapper in `servers/memory/mcp/` (`mcp==1.30.0`). Tools `memory_search/add/list/delete`.
    - `memory-api`: the official mem0 REST server, built from git context `mem0.git#v2.2.1:server` with a `dockerfile_inline` that pins `mem0ai`. Host port 8083.
    - `memory-dashboard`: built from `mem0.git#v2.2.1:server/dashboard`. Host port 8082. Its browser JS calls the API on 8083 directly.
    - `memory-postgres`: pgvector, on internal network `memory`.
  - The wrapper authenticates to mem0 with `ADMIN_API_KEY` from `memory.env`, so no two-phase rollout is needed.
  - `user_id` = end user's email from CyberArk IAM login. The wrapper lowercases and validates it, and `memory_delete` checks ownership. The agent backend puts the email in the system prompt.
  - After the first deploy, `POST /configure` sets 768-dim `text-embedding-005` with a new `collection_name`. mem0 creates a 1536-dim table at startup.
- **Fourth server: `postgres`** (demo DB with synthetic PII; guide section 15; gateway slug `postgres-db`).
  - Containers: `postgres-mcp` is MCP Toolbox for Databases (`us-central1-docker.pkg.dev/database-toolbox/toolbox/toolbox:1.14.0`, distroless, port 5000). `postgres-db` is `postgres:17.11`.
  - Toolbox serves `/mcp` with plain JSON and no session check, so the smoke test works as is.
  - Tools are declared in `servers/postgres/tools.yaml`; `${VAR}` there is expanded from the container env (`postgres.env`).
  - Tools: `query` uses role `agent_ro` (read-only transactions); `execute` uses `agent_rw` (DML only on schema `demo`, which the superuser owns).
  - `servers/postgres/init/` runs only on an empty volume. Reset = remove the containers plus volume `mcp-hub_postgres_data`.
  - The agent app's own MCP client (`~/Documents/my-ai-agent/agent-backend/app/tools.py`) needs a long httpx read timeout. It had httpx's 5 s default, which surfaced as "SSE stream ended without a response" on slow tools.
- **Pattern: databases with write access.** Enforce safety with DB roles: one tool per role (read-only vs DML), tables owned by another role, statement timeouts. Then let the gateway decide which agents get the write tool. Never rely on tool descriptions for safety.
- **Pattern: wrapping an upstream REST service.** When a project has no usable self-hosted MCP (or a stateful one), run its official server and write a small stateless FastMCP wrapper (Option C) that calls its REST API. Validate identifiers in the wrapper, and return short errors without stack traces or keys.
- **Guides:** `../github-actions-deploy-guide.md` (setup and deploy) and `../mcp-hub-guide.md` (architecture, section 9 recipe, section 7 gateway, troubleshooting).

## Hub layout and conventions

```
mcp-hub/
├── compose.yaml                             # proxy + include: list of servers/<name>/compose.yaml
├── proxy/templates/default.conf.template    # server :8080, /healthz, includes routes/, else 404
├── proxy/templates/routes/<name>.conf.template   # one per server; token check + proxy_pass
├── proxy/snippets/mcp-proxy.conf            # streaming, timeouts, strips Authorization
├── servers/<name>/compose.yaml              # the backend service(s)
├── servers/_template/                       # compose.yaml (options A/B/C) + route.conf.template.example
└── scripts/deploy.sh
```

| Item | Rule (example `weather`) |
|---|---|
| Name | lowercase letters, digits, hyphens: `weather` |
| Token variable | `MCP_TOKEN_` + uppercase name, hyphens → `_`: `MCP_TOKEN_WEATHER` |
| Backend | service/`container_name` `weather-mcp` (unique), listens on `0.0.0.0:<port>`, serves **Streamable HTTP at `/mcp`**, **no `ports:`** |
| Route | `proxy/templates/routes/weather.conf.template`: `location /weather/`, token `${MCP_TOKEN_WEATHER}`, `set $upstream http://weather-mcp:<port>;` |
| Public URL | `http://192.168.110.25:8080/weather/mcp` |
| Backend secrets | `env_file: ${HOME}/mcp-secrets/weather.env` (must use this exact form, which CI and deploy.sh grep for) |

## Workflow

1. **Identify the server.** Get the package, image or repo from the user, and research it: transport (stdio / Streamable HTTP / SSE-only), port, required env vars and API keys, whether it's stateless, and which tools it exposes. Pin exact versions (image tag or npm version), never `latest` for new servers.
2. **Pick the option** from `servers/_template/compose.yaml`:
   - **A:** the image already speaks Streamable HTTP. Run it directly.
   - **B:** stdio-only (`npx`/`uvx` servers). Wrap it with `supercorp/supergateway` using `--stdio "<cmd>" --outputTransport streamableHttp --port 8000` (serves `/mcp`). Pin the supergateway tag.
   - **C:** custom code in the folder (`build: .` + Dockerfile).
   - **SSE-only servers:** don't expose SSE through the proxy (SSE's `/messages` URL loses the `/<name>` prefix). Use a Streamable HTTP mode or a wrapper instead.
3. **Create the files:**
   - `servers/<name>/compose.yaml`, based on the template: remove the unused options and comments.
   - Add `- servers/<name>/compose.yaml` to `include:` in root `compose.yaml`.
   - `proxy/templates/routes/<name>.conf.template`, copied from `servers/_template/route.conf.template.example` with `example`/`EXAMPLE` replaced and the port set.
   - Don't copy the `.example` file into the new server folder.
   - Don't add tokens anywhere; deploy.sh generates them.
4. **Check locally:**
   - `bash -n scripts/deploy.sh`.
   - Re-read the route and compose files for name, port and token consistency.
   - `git status` shows no `*.env` files.
5. **Tell the user what to do on the server before pushing** (only if the backend needs API keys). As `mwan`, no sudo:
   ```bash
   nano ~/mcp-secrets/<name>.env      # KEY=value, no quotes, no spaces around =
   chmod 600 ~/mcp-secrets/<name>.env
   ```
6. **Commit and push only when the user asks.** From `mcp-hub/`: `git add -A && git status`, then commit and push. The push *is* the deploy. Then:
   - The Actions log shows `NEW tokens were generated: MCP_TOKEN_<NAME>`.
   - Get the token on the server: `grep '^MCP_TOKEN_<NAME>=' ~/mcp-secrets/hub.env | cut -d= -f2`.
7. **Test from another host.** Give ONE command when the user asks for a command:
   ```bash
   curl -sS -m 60 http://192.168.110.25:8080/<name>/mcp -H "Authorization: Bearer <TOKEN>" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
8. **Register in the AI Gateway:**

   | Field | Value |
   |---|---|
   | Name/slug | e.g. `<name>` or `<name>-search` |
   | Transport | Streamable HTTP |
   | URL | `http://192.168.110.25:8080/<name>/mcp` |
   | Auth | header `Authorization: Bearer <token>` |
   | Timeout | ≥ 60 s for slow tools |

   Then discover tools, enable only the needed ones, grant access only to the right agents, and turn on AIRS scanning of tool responses.
9. **Removing a server:** delete its `include:` line, its route template and its folder, then push. Optionally delete its line from `hub.env` and its `<name>.env` on the server.

## Gotchas

- **Stateful backends fail the smoke test.** deploy.sh sends a bare `tools/list` without `initialize`. A stateful server answers 400 ("no valid session ID"), so the smoke test fails. Prefer stateless mode:
  - FastMCP (Python): `stateless_http=True`.
  - TypeScript SDK: `sessionIdGenerator: undefined`.
  - supergateway: stateless unless `--stateful`.
  If it must be stateful, update deploy.sh's smoke test to `initialize` first and reuse the `Mcp-Session-Id`.
- **Stateful sessions are lost on every container restart or deploy.** The gateway then reports `Failed to restore session` (500) or 404 until the client reinitializes.
- **404 on `/<name>/mcp`:** route missing or misnamed (must be `*.conf.template`), URL missing `/mcp`, or a trailing slash. **401:** token mismatch. **502:** container name or port wrong, or the backend isn't listening on `0.0.0.0`.
- **Proxy fails with `unknown "mcp_token_x" variable`:** the token isn't in `hub.env`. A normal deploy fixes this; by hand, run `docker compose up -d --force-recreate proxy`.
- **Keep secrets out of committed `command:` lines.** Compose `${VAR}` interpolation does not read `env_file`. Instead:
  - pass secrets as container env vars (`env_file`), if the app reads them; or
  - use `sh -c '... "$$VAR"'` / `CMD-SHELL` so the value is expanded inside the container (see `servers/ragflow/compose.yaml`).
- **Backends whose API key is created in their own UI** (like RAGFlow) need two phases:
  1. Deploy the backend with its MCP service under `profiles: ["mcp"]` and no route yet.
  2. The user creates the key and puts it in `<name>.env`.
  3. Remove the profile line and add the route.
- **Multi-container stacks:** prefix every service and `container_name` with `<name>-` so it can't clash with other servers. Put internal services on their own network; only `<name>-mcp` joins `default`.
- **Headless-browser backends** need `shm_size: 2gb` and `init: true`.
- **Keep the gateway timeout** longer than the backend's slowest tool.
- **Name resolution:** the gateway may not resolve `mcphub.matthewwan.dev` (LAN DNS is the router `192.168.110.1`; public DNS is blocked). Register with the IP unless the user confirms DNS works.
- **Server-side permission problems:** `sudo chown -R mwan:mwan ~/mcp-secrets /opt/mcp-hub`. Docker socket denied: add `mwan` to the `docker` group, log in again, and restart the runner service (`cd ~/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh start`).

## How to talk to this user

Plain, step-by-step instructions with exact commands. Say which host each command runs on (Mac / `ubuntu-mcp-tools` / gateway host). When they ask for "one command", give exactly one. Update the relevant guide `.md` when a procedure changes.
