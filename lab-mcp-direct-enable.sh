#!/usr/bin/env bash
# Lab-only firewall exception: lets agent-backend's own container subnet reach mcp-hub's
# bearer-token proxy (port 8080) directly, for the "Task 1: talk to MCP tools directly"
# lab exercise. Kept as a SEPARATE, clearly-labeled rule from install.sh's main DOCKER-USER
# rule (which restricts port 8080 to the real AI Gateway's IP) — this does not touch or
# widen that rule, so the client/backend/MCP-hub tiers keep behaving like segmented firewall
# zones rather than one flattened network. Run lab-mcp-direct-disable.sh when done.
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
NETWORK_NAME="$(docker network ls --filter label=com.docker.compose.project=agent-backend --filter label=com.docker.compose.network=ai-net --format '{{.Name}}' | head -n1)"
if [ -z "$NETWORK_NAME" ]; then
  echo "ERROR: couldn't find agent-backend's ai-net Docker network. Start agent-backend first (./install.sh or ./deploy.sh)." >&2
  exit 1
fi

SUBNET="$(docker network inspect "$NETWORK_NAME" --format '{{(index .IPAM.Config 0).Subnet}}')"
if [ -z "$SUBNET" ]; then
  echo "ERROR: couldn't read ${NETWORK_NAME}'s subnet from Docker. Is my-ai-agent/agent-backend/docker-compose.yml's ai-net.ipam.config set?" >&2
  exit 1
fi
echo "==> agent-backend's ai-net network ($NETWORK_NAME) subnet: $SUBNET"

if ! sudo iptables -C DOCKER-USER -p tcp -s "$SUBNET" -m conntrack --ctorigdstport 8080 -j ACCEPT 2>/dev/null; then
  sudo iptables -I DOCKER-USER -p tcp -s "$SUBNET" -m conntrack --ctorigdstport 8080 -j ACCEPT
  echo "==> inserted DOCKER-USER ACCEPT rule for $SUBNET -> port 8080"
else
  echo "==> DOCKER-USER ACCEPT rule for $SUBNET -> port 8080 already present"
fi

# Persisted via a small systemd oneshot unit (same pattern install.sh uses for its own
# DOCKER-USER rule) rather than iptables-persistent, which still conflicts with ufw.
LAB_RULE="iptables -C DOCKER-USER -p tcp -s ${SUBNET} -m conntrack --ctorigdstport 8080 -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -p tcp -s ${SUBNET} -m conntrack --ctorigdstport 8080 -j ACCEPT"

sudo tee /etc/systemd/system/lab-mcp-direct.service >/dev/null <<EOF
[Unit]
Description=Lab-only: allow agent-backend's ai-net subnet to reach mcp-hub's port 8080 directly
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${LAB_RULE}'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now lab-mcp-direct.service >/dev/null

echo
echo "==> Lab direct-access firewall exception is active."
echo "    This is IN ADDITION TO the AI Gateway's existing rule, not a replacement — the"
echo "    MCP hub's port 8080 still rejects traffic from anywhere else."
echo "    Run ./lab-mcp-direct-disable.sh when the lab session is over."
echo

TOKENS_FILE="$HOME/mcp-secrets/hub.env"
if [ -f "$TOKENS_FILE" ] && grep -q '^MCP_TOKEN_LAB_DIRECT=' "$TOKENS_FILE"; then
  echo "MCP_TOKEN_LAB_DIRECT (give this to candidates for Task 1's Gateway API Key field):"
  grep '^MCP_TOKEN_LAB_DIRECT=' "$TOKENS_FILE"
else
  echo "NOTE: MCP_TOKEN_LAB_DIRECT isn't in $TOKENS_FILE yet."
  echo "      Run: (cd my-mcp-tools/mcp-hub && ./scripts/deploy.sh)   to generate it, then re-run this script."
fi

echo
echo "Server IP for candidates to use as the MCP Gateway URL (http://<this-ip>:8080):"
ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' \
  || hostname -I 2>/dev/null | awk '{print $1}' \
  || echo "  (couldn't auto-detect — check with 'ip addr' or 'hostname -I')"
