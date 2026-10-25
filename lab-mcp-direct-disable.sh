#!/usr/bin/env bash
# Reverses lab-mcp-direct-enable.sh: removes the lab-only DOCKER-USER exception and its
# systemd unit, restoring strict zone segmentation (only the real AI Gateway's IP can reach
# mcp-hub's port 8080). Safe to run even if the exception was never enabled.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
fi

if systemctl list-unit-files lab-mcp-direct.service >/dev/null 2>&1; then
  sudo systemctl disable --now lab-mcp-direct.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/lab-mcp-direct.service
  sudo systemctl daemon-reload
  echo "==> removed lab-mcp-direct.service"
else
  echo "==> lab-mcp-direct.service wasn't installed, nothing to remove there"
fi

if docker network inspect ai-net >/dev/null 2>&1; then
  SUBNET="$(docker network inspect ai-net --format '{{(index .IPAM.Config 0).Subnet}}')"
  if [ -n "$SUBNET" ] && sudo iptables -C DOCKER-USER -p tcp -s "$SUBNET" -m conntrack --ctorigdstport 8080 -j ACCEPT 2>/dev/null; then
    sudo iptables -D DOCKER-USER -p tcp -s "$SUBNET" -m conntrack --ctorigdstport 8080 -j ACCEPT
    echo "==> removed the live DOCKER-USER ACCEPT rule for $SUBNET -> port 8080"
  else
    echo "==> no matching live DOCKER-USER rule found (already removed, or ai-net's subnet changed)"
  fi
else
  echo "==> ai-net network not found (agent-backend not running) — nothing to remove at the iptables level"
fi

echo
echo "==> Lab direct-access exception removed. Only the AI Gateway's configured IP can reach port 8080 now."
