#!/usr/bin/env bash
# Non-interactive redeploy: brings every stack up to date using whatever .env files and
# ~/mcp-secrets/ are already on this server. This is what GitHub Actions runs on every push
# to main (.github/workflows/deploy.yml), and it's safe to run by hand too.
#
# This is NOT the first-time setup script. For a brand-new server (prerequisites, the
# domain prompt, firewall rules, dashboard/ragui credentials), run ./install.sh once first —
# that one's interactive and only needs to happen once per server.
#
# Run as the same normal sudo-capable user install.sh was run as (the self-hosted GitHub
# Actions runner should also run as this user), not root.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

for f in edge-proxy/.env my-ai-agent/agent-backend/.env my-ai-agent/client-chat-ui/.env my-mcp-tools/mcp-hub/.env; do
  if [ ! -f "$ROOT/$f" ]; then
    echo "ERROR: $f is missing. Run ./install.sh once on this server before the first deploy." >&2
    exit 1
  fi
done

echo "==> mcp-hub"
( cd "$ROOT/my-mcp-tools/mcp-hub" && ./scripts/deploy.sh )

echo
echo "==> agent-backend"
( cd "$ROOT/my-ai-agent/agent-backend" && docker compose up -d --build --remove-orphans )

echo
echo "==> client-chat-ui"
( cd "$ROOT/my-ai-agent/client-chat-ui" && docker compose up -d --build --remove-orphans )

echo
echo "==> edge-proxy"
( cd "$ROOT/edge-proxy" && docker compose up -d --build --remove-orphans )

echo
echo "==> status"
( cd "$ROOT/my-ai-agent/agent-backend" && docker compose ps )
( cd "$ROOT/my-ai-agent/client-chat-ui" && docker compose ps )
( cd "$ROOT/edge-proxy" && docker compose ps )
( cd "$ROOT/my-mcp-tools/mcp-hub" && docker compose ps )
