# Progress Report — agent-all-in-one Lab

_Last updated: 2026-11-02_

## 1. What's been done

### Consolidation & deployment
- Consolidated the previously 3-server architecture (chat client, backend agent, MCP tools)
  onto one Ubuntu server, kept logically separated by Docker Compose project / port.
- `install.sh` (interactive, first-time setup) and `deploy.sh` (non-interactive, CI) plus a
  GitHub Actions self-hosted-runner pipeline.
- Replaced RAGFlow with Chroma for RAG.
- Fixed a string of real deployment bugs along the way: Docker group permissions, `ufw` vs
  `iptables-persistent` package conflicts, the Chroma healthcheck, `$`-interpolation secret
  corruption, Let's Encrypt rate-limit defaults, a double-scheme WebSocket bug, CORS
  failures, and dashboard/Redis networking breaking after pinning a subnet.

### MCP lab: direct access vs. AI-Gateway-mediated access
- Added a shared `MCP_TOKEN_LAB_DIRECT` token accepted by `mcp-hub`'s nginx alongside each
  server's real per-server bearer token (no `agent-backend`/dashboard code changes needed
  for this part).
- Found and fixed a real architecture bug: `gateway_api_key` was shared between LLM chat
  completions and MCP tool-call auth, which would have broken chat as a side effect of the
  lab exercise. Added a genuinely separate `mcp_api_key` config value (Redis + dashboard UI
  in `McpServers.tsx`, backend `main.py`/`tools.py`), falling back to `gateway_api_key` when
  unset.
- Discovered the original firewall-exception design for direct access was fundamentally
  broken by a same-host hairpin NAT limitation in the Linux kernel (confirmed via
  `tcpdump`). Replaced it with a dual-homed `lab-mcp-relay` container instead.
- Found and fixed two real, pre-existing production bugs in `install.sh`'s `DOCKER-USER`
  firewall rule for `mcp-hub` port 8080 (both diagnosed via packet traces):
  - Missing an `ESTABLISHED,RELATED` ACCEPT rule, which was silently dropping reply traffic.
  - The DROP rule had no destination scoping, so it was also blocking unrelated outbound
    traffic to port 8080 on other hosts.
- Diagnosed the `mcphub.<domain>` anomaly some had noticed: a harmless, unused DNS record
  pointing at the server, hit by Caddy's generic HTTP→HTTPS redirect — not real config
  drift.

### Documentation
- Merged `ARCHITECTURE.md`, `DEPLOYMENT.md`, `LAB.md`, `LAB_ARCHITECTURE.md`,
  `API_ENDPOINTS.md`, `AUTHENTICATION.md`, and `mcp-hub-guide.md` into a single
  `LAB_GUIDE.md`, fixing significant staleness found in each (fictional `gateway_mode`,
  stale AIRS/RAGFlow references, wrong firewall descriptions) before deleting the originals.
- Structured `LAB_GUIDE.md` into student exercises (Part A: chatbot deployment; Part B:
  direct MCP tool access; Part C: AI Red Teaming, linking directly to the three official
  Palo Alto Networks Prisma AIRS docs) plus an Appendix (1–5) for admin/reference material.
- Rewrote `CLAUDE.md` and `mcp-hub`'s `add-mcp-server` skill to remove stale
  pre-consolidation architecture references and point at `LAB_GUIDE.md`.
- Built a Puppeteer-based Markdown→PDF pipeline (markdown-it + mermaid.js +
  github-markdown-css) producing `LAB_GUIDE.pdf` with real rendered diagrams, not code
  blocks.

### Public repo cleanup
- Security/privacy review before pushing to the new public `lab-agent-all-in-one` repo: no
  hardcoded secrets found, but cleaned up hardcoded personal domain/IP defaults in actual
  running code (`main.py`, `constants.ts`, `memory/compose.yaml` → new `MEM0_GATEWAY_URL`
  prompt in `install.sh`), removed dead Streamlit dashboard code, and removed stale
  `.env.example` files referencing a long-removed Okta auth system (including a real tenant
  ID).
- Pushed full history to both the private and new public remotes.

### Live student-support hardening
- Diagnosed a missing-`edge-proxy` report as `install.sh`'s fail-fast (`set -euo pipefail`)
  behavior aborting before the last step ran, after an earlier step errored.
- Diagnosed `"Sign in failed"` as a misleading NextAuth error actually caused by a TLS trust
  failure (`UNABLE_TO_GET_ISSUER_CERT_LOCALLY`) when running Caddy in
  `CADDY_LOCAL_CERTS=local_certs` mode. Built `trust-caddy-local-ca.sh` (idempotent,
  committed) to extract Caddy's internal CA and make `chat_ui`'s Node process trust it via
  `NODE_EXTRA_CA_CERTS`.
- Diagnosed `EAI_AGAIN`/`ENOTFOUND` DNS failures for two separate students using reserved/
  special-use TLDs as `BASE_DOMAIN` (`.local`, `.test`) — both guaranteed to never resolve.
  After the second occurrence confirmed this as a recurring pattern, added a hard validation
  check to `install.sh` rejecting `.local`/`.test`/`.example`/`.invalid`/`.localhost`/
  `.internal` and suggesting `nip.io` as the fix. Committed and pushed to both remotes.

## 2. What's still needed / open

- **Confirm the in-flight student issues are actually resolved.** The `admin:P@ssw0rd`
  `CredentialsSignin` student was asked to force-recreate the `agent` container and retry;
  the `ai.test` student was given the `nip.io` + re-run-`install.sh` + `trust-caddy-local-
  ca.sh` remediation. Neither result has been reported back — don't assume success.
- **`LAB_GUIDE.md` doesn't yet document the two newest fixes.** Neither
  `trust-caddy-local-ca.sh` nor the reserved-TLD `BASE_DOMAIN` guidance is mentioned in the
  guide, even though both are now part of the standard install flow. Worth adding a short
  note (likely Appendix 1 or 2) so students hitting these issues can self-serve instead of
  needing live support each time.
- **`LAB_GUIDE.pdf` regeneration.** Not committed to git. Decide whether to commit it or
  treat it as a regenerate-on-demand artifact — and if keeping it around, regenerate it once
  the above doc update lands.
- **`instruction.txt`'s pending deletion.** A long-standing uncommitted deletion (file
  missing from disk, never un-staged or restored) surfaced via `git add -A`. Still sitting
  unstaged; needs a decision — commit the deletion or restore the file.
- **Proactively notify the whole class** about the `BASE_DOMAIN` guidance: anyone without a
  real domain should use `<server-ip-with-dashes>.nip.io` from the start, to head off this
  class of issue before it recurs for someone not yet hit by it.
- **Part C content** is intentionally just links to the official Palo Alto Networks Prisma
  AIRS docs — no further write-up needed; the live walkthrough happens in the workshop
  itself, not in the repo.
