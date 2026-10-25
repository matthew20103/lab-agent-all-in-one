#!/usr/bin/env bash
# Reverses lab-mcp-direct-enable.sh: removes the lab-only relay container (and, for anyone
# who ran an older version of the enable script, any leftover firewall exception from the
# pre-redesign approach it replaced), restoring strict zone segmentation. Safe to run even
# if nothing was ever enabled.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
fi

if docker rm -f lab-mcp-relay >/dev/null 2>&1; then
  echo "==> removed lab-mcp-relay"
else
  echo "==> lab-mcp-relay wasn't running, nothing to remove there"
fi

# Old (pre-redesign) firewall-exception approach — cleaned up here too in case it's still
# active from before lab-mcp-direct-enable.sh switched to the relay-container approach.
if systemctl list-unit-files lab-mcp-direct.service >/dev/null 2>&1; then
  sudo systemctl disable --now lab-mcp-direct.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/lab-mcp-direct.service
  sudo systemctl daemon-reload
  echo "==> removed the old lab-mcp-direct.service firewall exception"
else
  echo "==> no old-style firewall exception found, nothing more to remove"
fi

NETWORK_NAME="$(docker network ls --filter label=com.docker.compose.project=agent-backend --filter label=com.docker.compose.network=ai-net --format '{{.Name}}' | head -n1)"
if [ -n "$NETWORK_NAME" ]; then
  SUBNET="$(docker network inspect "$NETWORK_NAME" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  if [ -n "$SUBNET" ] && sudo iptables -C DOCKER-USER -p tcp -s "$SUBNET" -m conntrack --ctorigdstport 8080 -j ACCEPT 2>/dev/null; then
    sudo iptables -D DOCKER-USER -p tcp -s "$SUBNET" -m conntrack --ctorigdstport 8080 -j ACCEPT
    echo "==> removed the old live DOCKER-USER ACCEPT rule for $SUBNET -> port 8080"
  fi
fi

echo
echo "==> Lab direct-access bridge removed."
