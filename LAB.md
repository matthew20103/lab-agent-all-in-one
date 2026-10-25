# MCP lab: direct access vs. AI-Gateway-mediated access

Two sequential tasks for candidates on this deployment:

1. **Task 1**: configure the agent to call MCP tools *directly* against `mcp-hub`, bypassing
   the AI Gateway entirely.
2. **Task 2**: reconfigure so every MCP tool call instead routes *through* the AI Gateway —
   the production design this whole project otherwise uses.

The contrast is the point: Task 1 uses one flat, shared credential with no per-tool policy;
Task 2 gives each MCP server its own token plus Prisma AIRS guardrail scanning and per-agent
access control.

---

## Why this needs one small firewall exception (admin, one-time)

`agent-backend` and `mcp-hub` are deliberately separate Docker Compose projects on separate
networks — `mcp-hub`'s bearer-token proxy (port 8080) is normally firewalled to only the real
AI Gateway's IP, so the three tiers keep behaving like genuinely separate, segmented
servers rather than one flat network. Task 1 needs `agent-backend` to reach that port too, so
before candidates start:

```bash
./lab-mcp-direct-enable.sh
```

This adds a **separate, clearly-labeled** `DOCKER-USER` firewall rule allow-listing
`agent-backend`'s own container subnet — it does not touch or widen the AI Gateway's existing
rule. It prints two things candidates will need:

- `MCP_TOKEN_LAB_DIRECT` — the shared lab-only token (from `~/mcp-secrets/hub.env`)
- the server's LAN IP

If `MCP_TOKEN_LAB_DIRECT` isn't printed yet, run `(cd my-mcp-tools/mcp-hub && ./scripts/deploy.sh)`
once to generate it (it's auto-created the same way every other `MCP_TOKEN_*` is), then re-run
`lab-mcp-direct-enable.sh`.

When the lab session is over, run `./lab-mcp-direct-disable.sh` to remove the exception and
restore strict zone segmentation.

---

## Task 1: talk to MCP tools directly

All of this happens in the admin dashboard (`https://dashboard.{domain}`) — no code changes.

1. **Gateway Mode → "Direct (No Gateway)".** Do this first. The gateway API key field you're
   about to repurpose below is shared between LLM chat-completions routing and MCP
   authentication in the current code — leaving Gateway Mode on a Portkey-routed setting
   while you overwrite that key with the lab token would break normal chat replies too.
   Direct mode sends LLM calls straight to DeepSeek/Ollama instead, so it doesn't depend on
   this key at all (Prisma AIRS prompt scanning is independent of this setting and keeps
   working either way).
2. **MCP Servers tab**:
   - **MCP Gateway URL**: `http://<server-LAN-IP>:8080` — use the real LAN IP printed by
     `lab-mcp-direct-enable.sh`, not `127.0.0.1` (that resolves to the agent's own container,
     not the host).
   - Add servers with slugs **exactly** `openserp`, `chroma`, `memory`, `postgres` — these
     must match `mcp-hub`'s nginx route names character-for-character, since the backend
     builds each tool's URL as `{MCP Gateway URL}/{slug}/mcp`. Enable the ones you want.
   - **Gateway API Key**: the `MCP_TOKEN_LAB_DIRECT` value from setup.
3. **Verify**: use each server's **Test** button in the dashboard first (fastest feedback),
   then confirm in the actual chat UI — e.g. ask it to search the web and check that
   `openserp` fires, or ask it something that should pull from the knowledge base
   (`chroma`) or long-term memory (`memory`).

If a Test fails, check `docker compose logs -f` on both `mcp-hub`'s `proxy` service and
`agent-backend`'s `agent` service while retrying — a `401` there means the token/URL isn't
matching; a connection failure/timeout more likely means the firewall exception from the
previous section isn't active yet, or `agent-backend` needs a restart to pick up its pinned
`ai-net` subnet (`docker compose up -d --force-recreate` in `my-ai-agent/agent-backend/`).

---

## Task 2: route every MCP tool call through the AI Gateway

1. **Register each MCP server in the real AI Gateway** (Portkey / Prisma AIRS admin
   console), one at a time, using that server's **own** real per-server token — not the lab
   token from Task 1. Find each one in `~/mcp-secrets/hub.env`:
   `MCP_TOKEN_OPENSERP`, `MCP_TOKEN_CHROMA`, `MCP_TOKEN_MEMORY`, `MCP_TOKEN_POSTGRES`.
   Follow the same steps `my-mcp-tools/mcp-hub-guide.md` §7 already documents (URL format,
   Streamable HTTP transport, least-privilege tool allow-listing, turning on AIRS response
   scanning, per-agent access grants).
2. **Back in the dashboard's MCP Servers tab**, change:
   - **MCP Gateway URL** → the AI Gateway's own MCP endpoint (not `mcp-hub` directly anymore)
   - **Gateway API Key** → the real Portkey API key
3. Optionally switch **Gateway Mode** back to a Portkey-routed mode too, now that the shared
   key is a real gateway credential again rather than the lab token.
4. **Verify**: same Test buttons and chat prompts as Task 1, but now also confirm each tool
   call shows up in the AI Gateway's own logs/traces, and that a response flagged by AIRS
   (e.g. the Postgres demo DB's synthetic SSNs/card numbers) actually gets scanned or
   blocked — that per-tool guardrail behavior is the capability Task 1's direct path didn't
   have at all.

---

## Cleanup

```bash
./lab-mcp-direct-disable.sh
```
Removes the firewall exception. The dashboard's MCP config (gateway URL/key, enabled
servers) isn't reset by this — reset it by hand in the dashboard if you're resetting the lab
for the next candidate.
