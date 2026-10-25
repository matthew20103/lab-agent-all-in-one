#!/usr/bin/env bash
# Lab-only direct-access bridge: lets agent-backend's agent/dashboard containers reach
# mcp-hub's proxy directly over Docker's internal networking, for the "Task 1: talk to
# MCP tools directly" lab exercise.
#
# This does NOT go through the host's own LAN IP / published port 8080, unlike an earlier
# version of this script. Reason: a container on this same host reaching mcp-hub's
# published port via the host's own LAN/public IP hits a well-known Linux NAT/routing-order
# bug. Docker's hairpin masquerade rewrites the request's source to the target bridge's own
# (local) gateway IP; the kernel undoes the DNAT (fixing the reply's source) at PREROUTING,
# but only undoes that masquerade (fixing the reply's destination) later at POSTROUTING —
# and the routing decision in between still sees a local destination, so the reply gets
# delivered to the host itself instead of being forwarded back. It's silently swallowed.
# This only bites same-host container traffic; it never happens for the real AI Gateway,
# which is a genuinely separate machine reaching mcp-hub over a real network link.
#
# The fix: add one small, disposable, single-purpose relay container (`lab-mcp-relay`,
# plain socat, forwards port 8080 to mcp-proxy and nothing else) that's a member of BOTH
# agent-backend's own network and mcp-hub's own network. agent-backend's `agent` and
# `dashboard` containers are already on their own network, so once this relay joins it they
# can resolve and reach `lab-mcp-relay:8080` directly. Unlike joining agent-backend's own
# containers to mcp-hub's network, the relay can't be used to reach anything else over
# there — it only knows how to forward one port to one destination. Run
# lab-mcp-direct-disable.sh when done.
#
# Run as the same normal sudo-capable user install.sh was run as, not root.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

# Compose prefixes network names with the project name (defaults to the compose file's
# folder, "agent-backend") rather than using the bare name declared in docker-compose.yml —
# so the real Docker network is "agent-backend_ai-net", not "ai-net". Look it up via
# Compose's own labels instead of guessing the exact prefix/separator convention.
AI_NET="$(docker network ls --filter label=com.docker.compose.project=agent-backend --filter label=com.docker.compose.network=ai-net --format '{{.Name}}' | head -n1)"
if [ -z "$AI_NET" ]; then
  echo "ERROR: couldn't find agent-backend's ai-net Docker network. Start agent-backend first (./install.sh or ./deploy.sh)." >&2
  exit 1
fi
echo "==> agent-backend's network: $AI_NET"

# mcp-hub's proxy container's own network — read directly off the running container rather
# than guessing mcp-hub's compose project/network naming convention.
MCP_HUB_NET="$(docker inspect mcp-proxy --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)"
if [ -z "$MCP_HUB_NET" ]; then
  echo "ERROR: couldn't find mcp-hub's proxy container ('mcp-proxy'). Start mcp-hub first (cd my-mcp-tools/mcp-hub && ./scripts/deploy.sh)." >&2
  exit 1
fi
echo "==> mcp-hub's network: $MCP_HUB_NET"

# Clean up the old (pre-redesign) firewall-exception approach if it's still active from a
# previous run of this script — it's superseded by the relay container below.
if systemctl list-unit-files lab-mcp-direct.service >/dev/null 2>&1; then
  sudo systemctl disable --now lab-mcp-direct.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/lab-mcp-direct.service
  sudo systemctl daemon-reload
  echo "==> removed the old lab-mcp-direct.service firewall exception (superseded by the relay container below)"
fi

docker rm -f lab-mcp-relay >/dev/null 2>&1 || true
docker run -d --name lab-mcp-relay --network "$AI_NET" alpine/socat \
  TCP-LISTEN:8080,fork,reuseaddr TCP:mcp-proxy:8080 >/dev/null
docker network connect "$MCP_HUB_NET" lab-mcp-relay
echo "==> lab-mcp-relay is up, bridging agent-backend's network to mcp-proxy:8080"

echo
echo "==> Lab direct-access bridge is active."
echo "    Only this one relay container can reach mcp-hub's network, and it only forwards"
echo "    port 8080 to mcp-proxy — nothing else there is reachable through it."
echo "    Run ./lab-mcp-direct-disable.sh when the lab session is over."
echo

TOKENS_FILE="$HOME/mcp-secrets/hub.env"
if [ -f "$TOKENS_FILE" ] && grep -q '^MCP_TOKEN_LAB_DIRECT=' "$TOKENS_FILE"; then
  echo "MCP_TOKEN_LAB_DIRECT (give this to candidates for Task 1's MCP API Key field):"
  grep '^MCP_TOKEN_LAB_DIRECT=' "$TOKENS_FILE"
else
  echo "NOTE: MCP_TOKEN_LAB_DIRECT isn't in $TOKENS_FILE yet."
  echo "      Run: (cd my-mcp-tools/mcp-hub && ./scripts/deploy.sh)   to generate it, then re-run this script."
fi

echo
echo "MCP Gateway URL for candidates to use: http://lab-mcp-relay:8080"
