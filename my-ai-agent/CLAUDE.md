# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository. It's intentionally short — for human-facing architecture, deployment, lab, and API
documentation, see `LAB_GUIDE.md` at the repo root. This file covers only what's useful for an
AI assistant navigating and editing this code specifically, and should stay current with the
actual code rather than aspirational/removed functionality.

## Overview

Part of a larger "all-in-a-box" consolidation (see `LAB_GUIDE.md` section D) — four
independently-deployed Docker Compose projects on one Ubuntu server, fronted by a single shared
`edge-proxy` (Caddy). This `my-ai-agent/` folder contains two of those four:

- **`agent-backend/`** — FastAPI agent server (`app/main.py`), Redis (session + live config),
  and a Next.js admin dashboard (`agent-dashboard/`, bundled into the same Compose project,
  sharing its Docker network).
- **`client-chat-ui/`** — a Next.js chat client (the end-user workspace), talking to the
  backend over HTTPS/WSS only.

The platform demonstrates enterprise AI guardrails: CyberArk Identity (Idira) OAuth2/OIDC auth
and Portkey/Prisma AIRS gateway routing for both LLM calls and MCP tool calls. **Do not assume
this codebase implements every guardrail a demo narrative might describe** — verify against the
actual code before documenting or building on top of a claimed behavior (see "Verify before
you document" below for why this matters here specifically).

## Running

Each stack is brought up independently with Docker Compose. For the full, current process
(prerequisites, `install.sh`/`deploy.sh`, CI/CD), see `LAB_GUIDE.md` sections A and E — don't
rely on ad-hoc `docker compose up` instructions from memory, since the exact env/firewall setup
matters.

There is no test suite, linter, or build step beyond the Docker image builds. Python
dependencies live in `agent-backend/app/requirements.txt`.

## Architecture & key concepts

### Live configuration via Redis

The backend has almost no static behavior config. The Next.js dashboard writes settings into
Redis keys (`config:system_prompt`, `config:gateway_url`, `config:gateway_api_key`,
`config:mcp_api_key`, `config:mcp_gateway_url`, `config:mcp_servers`, `config:a2a_agents`), and
every request reads them fresh via `get_live_config()` in `main.py`. Changing a prompt, gateway
settings, or MCP servers in the dashboard takes effect on the next message with no restart.
When editing request handling, never cache config across requests — that breaks hot-reload.

**`gateway_api_key` and `mcp_api_key` are deliberately separate values**, despite both
defaulting to the same Portkey key in normal operation: `gateway_api_key` is used only by
`get_llm_client()` for LLM chat completions; `mcp_api_key` (falling back to `gateway_api_key`
when unset) is used only by `mcp_sessions_context()` for MCP tool-call auth. This split exists
specifically so MCP auth can point somewhere other than the real gateway (e.g. a lab exercise
calling an MCP hub directly) without breaking chat. Don't reintroduce a single shared variable
for both purposes.

MCP servers are managed on the Next.js dashboard's **MCP Servers** tab
(`agent-dashboard/src/components/McpServers.tsx`): add/remove, on/off per server, MCP Gateway
URL, MCP API Key, and a per-server **Test** that connects from the dashboard's own server
(`/api/mcp-servers/test`) using the saved URL/key. Stored in `config:mcp_servers` as an ordered
JSON list of `{slug, enabled}`. `get_live_config()` uses only the enabled slugs.

### Sessions

Conversation history is stored per session in Redis under `session:{id}` with a 1-hour TTL
(`SESSION_TTL`). History is trimmed to the system message + last 20 messages. The system prompt
slot (`messages[0]`) is always overwritten with the current live prompt on each turn.

### The four chat endpoints in `main.py`

All four implement the **same pipeline** — intent classify → load history → LLM call →
optional tool loop → save history — just with different transports. When changing pipeline
logic, you almost always need to change all four to keep them consistent. See
`LAB_GUIDE.md` section G for the full endpoint reference (paths, auth, request/response
shapes). `POST /api/v1/chat/public` is intentionally unauthenticated — keep this in mind for
security reviews.

### Gateway routing (`get_llm_client`)

There is no mode switch here — every LLM call, unconditionally, builds an `AsyncOpenAI` client
pointed at `gateway_url` (default `PORTKEY_GATEWAY_URL`) with header
`x-portkey-api-key: gateway_api_key`. If you're tempted to document or build around a
"Direct/Local Gateway/Cloud Gateway" mode concept, verify first — no such branching exists in
the current code.

### Tools (`tools.py`)

There are no locally-implemented tools — every tool lives behind the AI Gateway or (for the
lab's direct-access path) `mcp-hub` directly: MCP servers opened per-request in
`mcp_sessions_context()`/`get_mcp_tool_schemas()` and dispatched through `execute_mcp_tool()`,
plus A2A sub-agents. `execute_tool()` is a thin router: `mcp__`-prefixed names go to
`execute_mcp_tool`, `a2a__`-prefixed names to `a2a_agents.execute_a2a_tool`.

**A2A sub-agents** registered in the AI Gateway are managed on the dashboard's **Sub-agents**
tab and stored in `config:a2a_agents` as `{slug, url, enabled, card_url?}`. They always use
`gateway_api_key`, never `mcp_api_key` — the mcp_api_key/gateway_api_key split (above) is MCP-only.
`a2a_agents.py` resolves each card, picks the A2A transport, and exposes each agent as tool
`a2a__{slug}`. Not loaded on the unauthenticated `/api/v1/chat/public` endpoint.

Per-user MCP servers (`USER_SCOPED_MCP_SLUGS` in `tools.py`, currently `agent-memory`) never let
the model choose identity: `user_id` is stripped from their schemas, and `execute_mcp_tool`
overwrites it with the email from the **verified** Idira token
(`resolve_verified_email()`/`main.py`). Never source it from the client-supplied `user_info`
body.

### Auth (Idira, CyberArk Identity)

JWTs validated against Idira's JWKS (RS256) using `CYBERARK_ISSUER`/`CYBERARK_AUDIENCE`/
`CYBERARK_JWKS_URI` env vars (no hardcoded fallbacks — must be set in `.env`). Only the plain
`Bearer` scheme is accepted (no DPoP). See `LAB_GUIDE.md` section H for the full auth flow,
including the client-side NextAuth details.

## Conventions & gotchas

- `.env` files and several Dockerfiles contain **real-looking secrets**. Treat them as live; do
  not echo or commit them elsewhere.
- Tool-call streaming reassembles fragmented deltas by `tc.index` into `tool_calls_dict` —
  preserve that accumulation pattern when touching the streaming loops.
- Guardrail blocks from Portkey surface as HTTP 446; handlers special-case `"446"` +
  `"guardrail"` in the error string.
- **Verify before you document.** This file and other docs in this repo have previously
  described functionality (a `gateway_mode` config option, Prisma AIRS prompt-scanning code,
  intent-based model routing) that turned out not to exist anywhere in the actual code —
  apparently leftover from an earlier design that was simplified or never fully built. Before
  writing documentation, a lab exercise, or code that depends on a described behavior, grep the
  actual code to confirm it's real, rather than trusting prose in a markdown file (including
  this one) at face value.
