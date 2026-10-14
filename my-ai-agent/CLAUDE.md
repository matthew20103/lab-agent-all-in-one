# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A security-focused, multi-provider LLM agent platform. Two independently-deployed Docker stacks:

- **`agent-backend/`** — FastAPI agent server, Redis (session + live config), a Streamlit admin dashboard, and a Caddy reverse proxy. This is the brain.
- **`client-chat-ui/`** — A standalone Streamlit chat client (the end-user workspace) behind its own Caddy proxy. Talks to the backend over HTTPS/WSS only — no shared network with the backend stack.

The platform's purpose is to demonstrate enterprise AI guardrails: CyberArk Identity (Idira) OAuth2/OIDC auth, Palo Alto **Prisma AIRS** prompt scanning, **Portkey** gateway routing (local OSS gateway vs. Portkey Cloud vs. direct), and automatic intent-based model routing (coding → one route, writing → another).

## Running

Each stack is brought up independently with Docker Compose; there is no top-level compose file.

```bash
# Backend (from agent-backend/) — agent:8000, dashboard:8501, redis:6379, caddy:80/443/8443
cd agent-backend && docker compose up --build

# Client UI (from client-chat-ui/) — caddy:80/443, client_ui:8501 internal
cd client-chat-ui && docker compose up --build
```

There is no test suite, linter, or build step beyond the Docker image builds. Python dependencies live in `agent-backend/app/requirements.txt` (the client UI installs its deps inline in `Dockerfile.client`).

Both stacks expect a `.env` next to their `docker-compose.yml` supplying secrets/config (DeepSeek/Ollama keys, Portkey, CyberArk Identity (Idira), ACME-DNS).

## Public endpoints (via Caddy)

- `agent.matthewwan.dev:8443` → backend agent (note the **non-standard 8443 port**)
- `dashboard.matthewwan.dev` → admin dashboard
- `chat.matthewwan.dev` → client chat UI

Caddy obtains TLS certs via the ACME-DNS challenge. The client UI connects to the backend with TLS verification **disabled** (`verify=False`, `CERT_NONE`) — self-signed/internal certs are expected.

## Architecture & key concepts

### Live configuration via Redis
The backend has almost no static behavior config. The admin dashboard (`dashboard.py`) writes settings into Redis keys (`config:system_prompt`, `config:model_name`, `config:gateway_mode`, `config:security_airs*`, `config:mcp_gateway_url`, `config:mcp_servers`, `config:a2a_agents`), and every request reads them fresh via `get_live_config()` in `main.py`. Changing a model, prompt, or MCP servers in the dashboard takes effect on the next message with no restart. When editing request handling, never cache config across requests — that breaks hot-reload.

MCP servers are managed on the Next.js dashboard's **MCP Servers** tab (`agent-dashboard/src/components/McpServers.tsx`): add/remove, on/off per server, explicit Save, and a per-server **Test** that connects from the dashboard's own server (`/api/mcp-servers/test`, MCP TypeScript SDK) using the *saved* gateway URL and key. They're stored in `config:mcp_servers` as an ordered JSON list of `{slug, enabled}`. `get_live_config()` uses only the enabled slugs, falling back to the old comma-separated `config:mcp_server_slugs` (deleted on first save from the tab), then the `PORTKEY_MCP_SERVER_SLUGS` env default. The legacy Streamlit `dashboard.py` still writes the old key, which is ignored once `config:mcp_servers` exists.

### Sessions
Conversation history is stored per session in Redis under `session:{id}` with a 1-hour TTL (`SESSION_TTL`). History is trimmed to the system message + last 20 messages. The system prompt slot (`messages[0]`) is always overwritten with the current live prompt on each turn.

### The four chat endpoints in `main.py`
All four implement the **same pipeline** (intent classify → optional AIRS scan → load history → LLM call → optional tool loop → save history), just with different transports. When changing pipeline logic, you almost always need to change all four to keep them consistent:

1. `WS /ws` — WebSocket, streaming, CyberArk Identity (Idira)-authenticated. Used by the client UI's default "WebSocket (WSS)" mode.
2. `POST /api/v1/chat` — blocking REST, CyberArk Identity (Idira)-authenticated, uses Portkey `with_raw_response` to extract AIRS-masked text from `hook_results`.
3. `POST /api/v1/chat/stream` — SSE streaming, CyberArk Identity (Idira)-authenticated.
4. `POST /api/v1/chat/public` — **unauthenticated** blocking REST (no auth dependency). Keep this in mind for security reviews.

Plus `POST /api/v1/upload` (multimodal file ingestion into session history) and `POST /api/v1/feedback` (forwards 👍/👎 to Portkey by trace ID).

### Gateway routing (`get_llm_client`)
The active client is built per-request from `gateway_mode`:
- **Direct (No Gateway)** — straight to DeepSeek or Ollama.
- **Local Portkey Gateway** — routes through the self-hosted Portkey for observability/routing only; **AIRS edge guardrails are NOT applied** here (the code emits a warning when secure mode is on but gateway is local).
- **Portkey Cloud** — guardrails handled natively at the edge via `x-portkey-config`.

Model names prefixed `ollama/` (or containing `llama`) are treated as Ollama and the prefix is stripped before the API call; a `custom-host` header points Portkey at the Ollama server.

### Prisma AIRS security modes
`security_mode` per-request (`"secure"`/`"insecure"`) overrides the dashboard's AIRS toggle. In **Direct** mode the backend calls Palo Alto's AIRS scan API directly before the LLM and blocks on `"block"` in the result; it **fails open** on timeout/error. The client UI's split view sends `"insecure"` (left/Unprotected) and `"secure"` (right/Protected) simultaneously so the two can be compared side by side.

### Intent-based routing
`determine_task_type()` makes a cheap, gateway-bypassing DeepSeek call to classify each prompt as `coding` vs `writing`, then passes `{"task_type": ...}` as `x-portkey-metadata` so Portkey's conditional routing config can send coding to one provider and writing to another.

### Trace IDs & feedback
Each request generates one `current_trace_id` reused across the first LLM call, the tool follow-up call, and the AIRS scan so Portkey links them. It's sent to the UI, which attaches it to thumbs-up/down feedback posted back through `/api/v1/feedback`.

### Tools (`tools.py`)
There are no locally-implemented tools left — SearxNG, Ollama web search, and ChromaDB RAG were all removed in turn. Every tool now lives behind the AI Gateway: MCP servers on its MCP port (web search, RAG, memory, etc.), opened per-request in `mcp_sessions_context()`/`get_mcp_tool_schemas()` and dispatched through `execute_mcp_tool()`, plus A2A sub-agents (below). `execute_tool()` in `tools.py` is a thin router: `mcp__`-prefixed names go to `execute_mcp_tool`, `a2a__`-prefixed names to `a2a_agents.execute_a2a_tool`.

**A2A sub-agents** registered in the AI Gateway (e.g. `http://192.168.110.161/v1/agent/db-agent`) are managed on the dashboard's **Sub-agents** tab and stored in `config:a2a_agents` as `{slug, url, enabled, card_url?}`. The AI Gateway does agent-card discovery in its cloud control plane, so its own `{url}/.well-known/agent-card.json` returns only a stub (`{"url": "https://aigw.portkey.ai/..."}`) with no name or skills. `card_url` is an optional **card URL override**: empty means the card is read from `{url}/.well-known/agent-card.json`; set it to the agent's own card (e.g. `http://db-agent.matthewwan.dev:8080/.well-known/agent-card.json`) to work around the stub. The override is fetched **without** the gateway key, while all calls still go through `url`. `a2a_agents.py` (official `a2a-sdk`, pinned) resolves each card (from `card_url`, else from the gateway with the `x-portkey-api-key` header), picks the A2A v1.0 or v0.3 transport from the card (preferring **v0.3** when an agent offers both: the gateway drops the `A2A-Version` header, and A2A servers read a missing header as 0.3, so v1.0 requests are rejected with "A2A version '0.3' is not supported by this handler"), and exposes each agent as one tool `a2a__{slug}` described from its card. If the card advertises an endpoint on another host, calls are redirected to the configured gateway URL so they never bypass the gateway. Each chat keeps one conversation per sub-agent (A2A `contextId` in Redis `a2a_ctx:{session_id}:{slug}`, same 1h TTL as the session). Sub-agents are not loaded on the unauthenticated `/api/v1/chat/public` endpoint. A2A entries share `mcp_sessions_context`'s sessions dict under `a2a:{slug}` keys and are dispatched by `tools.execute_tool`.

Per-user MCP servers (`USER_SCOPED_MCP_SLUGS` in `tools.py`, currently `agent-memory` / mem0) never let the model choose identity: `user_id` is stripped from their schemas, and `execute_mcp_tool` overwrites it with the email from the **verified** Idira token (`resolve_verified_email()` in `main.py`: the `email` claim, falling back to Idira's userinfo endpoint, cached in Redis). Never source it from the client-supplied `user_info` body. With no verified email (Basic Auth, `/api/v1/chat/public`), those slugs aren't loaded at all.

### Auth (Idira, CyberArk Identity)
Migrated from Okta OAuth2 + DPoP to CyberArk Identity, whose current product name is "Idira", via a per-application OIDC discovery document (`{issuer}/.well-known/openid-configuration`) rather than Okta's tenant-wide authorization server. The backend validates JWTs against Idira's JWKS (RS256) using `CYBERARK_ISSUER`/`CYBERARK_AUDIENCE`/`CYBERARK_JWKS_URI` env vars (no hardcoded fallbacks — must be set in `.env`). The client UI's NextAuth provider (`id: 'cyberark'`, display name "Idira" — the id is kept stable because it's baked into the redirect URI already registered in the Idira console) uses `CYBERARK_ISSUER`/`CYBERARK_USER_CLIENT_ID`/`CYBERARK_USER_CLIENT_SECRET`. DPoP has been dropped entirely as dead weight; only the plain `Bearer` scheme is accepted in `verify_request_auth()` and the `/ws` handler. Okta has been fully removed from the codebase — `agent-dashboard` was never actually Okta-gated (its `OKTA_*` vars were vestigial; it's protected by Caddy `basicauth` instead), so those vars were deleted rather than migrated.

## Conventions & gotchas

- `.env` files and several Dockerfiles contain **real-looking secrets** (API keys, ACME-DNS creds, CyberArk client secret). Treat them as live; do not echo or commit them elsewhere.
- Auth is Idira (CyberArk Identity) end-to-end now — see the Auth section above. There is no Okta left in this codebase.
- Tool-call streaming reassembles fragmented deltas by `tc.index` into `tool_calls_dict` — preserve that accumulation pattern when touching the streaming loops.
- Guardrail blocks from Portkey surface as HTTP 446; the handlers special-case `"446"` + `"guardrail"` in the error string.
