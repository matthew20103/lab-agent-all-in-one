#!/usr/bin/env bash
# All-in-a-box installer: brings up client-chat-ui, agent-backend, mcp-hub and edge-proxy
# on a single, brand-new Ubuntu server. Checks/installs prerequisites, asks for the public
# domain once, wires every project's config to it, sets up the firewall, then starts
# everything. Safe to re-run (idempotent): re-running just updates config and restarts.
#
# Run as a normal sudo-capable user, NOT as root and NOT with `sudo ./install.sh` — the
# script calls sudo itself for the privileged steps (apt, ufw, iptables, sysctl, usermod).
# Docker Compose must run as your own user so files under ~/mcp-secrets/ stay owned by you
# (mcp-hub/scripts/deploy.sh already enforces this and will refuse to run otherwise).
#
# Assumes this whole project folder is already on the server (e.g. copied over with
# `rsync`/`scp`, the same way mcp-hub-guide.md already describes).

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

echo "== All-in-a-box installer =="
echo "Project root: $ROOT"
echo

# ---------------------------------------------------------------------------
# 1. OS check (warn, don't block)
# ---------------------------------------------------------------------------
if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || { [ "${VERSION_ID:-}" != "22.04" ] && [ "${VERSION_ID:-}" != "24.04" ]; }; then
    echo "WARNING: this was written for Ubuntu 22.04/24.04; detected ${PRETTY_NAME:-unknown}. Continuing anyway." >&2
  fi
else
  echo "WARNING: /etc/os-release not found; can't confirm this is Ubuntu. Continuing anyway." >&2
fi

# ---------------------------------------------------------------------------
# 2. Prerequisites: check first, install only what's missing
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites"

ensure_apt_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "   installing $pkg"
    sudo apt-get install -y "$pkg"
  fi
}

NEED_APT_UPDATE=0
for pkg in ca-certificates curl openssl ufw; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEED_APT_UPDATE=1
done
if ! command -v docker >/dev/null 2>&1; then NEED_APT_UPDATE=1; fi
if [ "$NEED_APT_UPDATE" -eq 1 ]; then
  sudo apt-get update
fi

for pkg in ca-certificates curl openssl ufw; do
  ensure_apt_pkg "$pkg"
done

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "   docker + compose plugin already present ($(docker compose version --short 2>/dev/null))"
else
  echo "   installing Docker Engine + Compose plugin"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

NEED_RELOGIN=0
if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  NEED_RELOGIN=1
fi

# iptables-persistent prompts interactively unless preseeded
if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
  echo "   installing iptables-persistent"
  echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
  echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi

if [ "$NEED_RELOGIN" -eq 1 ]; then
  echo
  echo "NOTE: added $USER to the 'docker' group. Log out and back in (or run 'newgrp docker')"
  echo "      before the 'docker compose up' steps below, or re-run this script after that."
  echo
fi

# ---------------------------------------------------------------------------
# 3. Prompts
# ---------------------------------------------------------------------------
echo
echo "==> Configuration"

existing() { # existing KEY FILE -> prints current value or empty
  [ -f "$2" ] && grep -E "^${1}=" "$2" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

default_domain="$(existing BASE_DOMAIN "$ROOT/edge-proxy/.env")"
read -rp "Base domain, e.g. example.com [${default_domain}]: " BASE_DOMAIN
BASE_DOMAIN="${BASE_DOMAIN:-$default_domain}"
[ -n "$BASE_DOMAIN" ] || { echo "ERROR: a base domain is required." >&2; exit 1; }

default_email="$(existing ACME_EMAIL "$ROOT/edge-proxy/.env")"
read -rp "Email for Let's Encrypt notifications [${default_email}]: " ACME_EMAIL
ACME_EMAIL="${ACME_EMAIL:-$default_email}"
[ -n "$ACME_EMAIL" ] || { echo "ERROR: an email is required for Let's Encrypt." >&2; exit 1; }

default_dash_user="$(existing DASHBOARD_USER "$ROOT/edge-proxy/.env")"
default_dash_user="${default_dash_user:-admin}"
read -rp "Admin dashboard username [${default_dash_user}]: " DASHBOARD_USER
DASHBOARD_USER="${DASHBOARD_USER:-$default_dash_user}"

existing_hash="$(existing DASHBOARD_PASSWORD_HASH "$ROOT/edge-proxy/.env")"
read -rsp "Admin dashboard password (leave blank to keep the existing one): " DASHBOARD_PASSWORD
echo
if [ -n "$DASHBOARD_PASSWORD" ]; then
  DASHBOARD_PASSWORD_HASH="$(docker run --rm caddy:latest caddy hash-password --plaintext "$DASHBOARD_PASSWORD")"
else
  DASHBOARD_PASSWORD_HASH="$existing_hash"
  [ -n "$DASHBOARD_PASSWORD_HASH" ] || { echo "ERROR: no existing password hash found; a password is required on first run." >&2; exit 1; }
fi

default_mcp_ui_user="$(existing MCP_UI_USER "$ROOT/edge-proxy/.env")"
default_mcp_ui_user="${default_mcp_ui_user:-admin}"
read -rp "MCP knowledge-base UI (ragui) username [${default_mcp_ui_user}]: " MCP_UI_USER
MCP_UI_USER="${MCP_UI_USER:-$default_mcp_ui_user}"

existing_mcp_ui_hash="$(existing MCP_UI_PASSWORD_HASH "$ROOT/edge-proxy/.env")"
read -rsp "MCP knowledge-base UI (ragui) password (leave blank to keep the existing one): " MCP_UI_PASSWORD
echo
if [ -n "$MCP_UI_PASSWORD" ]; then
  MCP_UI_PASSWORD_HASH="$(docker run --rm caddy:latest caddy hash-password --plaintext "$MCP_UI_PASSWORD")"
else
  MCP_UI_PASSWORD_HASH="$existing_mcp_ui_hash"
  [ -n "$MCP_UI_PASSWORD_HASH" ] || { echo "ERROR: no existing password hash found; a password is required on first run." >&2; exit 1; }
fi

default_gw_ip="$(existing GATEWAY_SOURCE_IP "$ROOT/.install-state")"
read -rp "AI Gateway source IP/CIDR allowed to reach the MCP hub on port 8080 [${default_gw_ip}]: " GATEWAY_SOURCE_IP
GATEWAY_SOURCE_IP="${GATEWAY_SOURCE_IP:-$default_gw_ip}"
[ -n "$GATEWAY_SOURCE_IP" ] || { echo "ERROR: the AI Gateway's source IP/CIDR is required to lock down port 8080." >&2; exit 1; }
printf 'GATEWAY_SOURCE_IP=%s\n' "$GATEWAY_SOURCE_IP" > "$ROOT/.install-state"

# ---------------------------------------------------------------------------
# 4. Write/upsert .env files (idempotent: only touches the keys we manage)
# ---------------------------------------------------------------------------
upsert_env_var() { # upsert_env_var FILE KEY VALUE
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" -F= '
    BEGIN { done = 0 }
    $1 == k { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

echo
echo "==> Writing configuration"

upsert_env_var "$ROOT/edge-proxy/.env" BASE_DOMAIN "$BASE_DOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" ACME_EMAIL "$ACME_EMAIL"
upsert_env_var "$ROOT/edge-proxy/.env" DASHBOARD_USER "$DASHBOARD_USER"
upsert_env_var "$ROOT/edge-proxy/.env" DASHBOARD_PASSWORD_HASH "$DASHBOARD_PASSWORD_HASH"
upsert_env_var "$ROOT/edge-proxy/.env" MCP_UI_USER "$MCP_UI_USER"
upsert_env_var "$ROOT/edge-proxy/.env" MCP_UI_PASSWORD_HASH "$MCP_UI_PASSWORD_HASH"

upsert_env_var "$ROOT/my-ai-agent/agent-backend/.env" BASE_DOMAIN "$BASE_DOMAIN"

upsert_env_var "$ROOT/my-ai-agent/client-chat-ui/.env" NEXT_PUBLIC_AGENT_BASE_URL "https://agent.${BASE_DOMAIN}"
upsert_env_var "$ROOT/my-ai-agent/client-chat-ui/.env" NEXTAUTH_URL "https://chat.${BASE_DOMAIN}"

upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" BASE_DOMAIN "$BASE_DOMAIN"

chmod 600 "$ROOT/edge-proxy/.env" "$ROOT/my-ai-agent/agent-backend/.env" \
  "$ROOT/my-ai-agent/client-chat-ui/.env" "$ROOT/my-mcp-tools/mcp-hub/.env"

# ---------------------------------------------------------------------------
# 5. Firewall
# ---------------------------------------------------------------------------
echo
echo "==> Firewall"

sudo ufw allow OpenSSH >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null

# Docker-published ports bypass ufw, so the MCP hub's bearer-token proxy (8080) is
# restricted directly in the DOCKER-USER chain instead, same as mcp-hub-guide.md section 6.
if ! sudo iptables -C DOCKER-USER -p tcp -m conntrack --ctorigdstport 8080 ! -s "$GATEWAY_SOURCE_IP" -j DROP 2>/dev/null; then
  sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 8080 ! -s "$GATEWAY_SOURCE_IP" -j DROP
fi
sudo netfilter-persistent save >/dev/null

sudo ufw --force enable >/dev/null
echo "   ufw: 22, 80, 443 allowed; port 8080 restricted to ${GATEWAY_SOURCE_IP} via DOCKER-USER"

# ---------------------------------------------------------------------------
# 6. Secrets checklist (this script never invents business secrets)
# ---------------------------------------------------------------------------
echo
echo "==> Before starting, make sure these are filled in (unchanged by this script):"
echo "   - my-ai-agent/agent-backend/.env         (PORTKEY_*, CYBERARK_*, BASIC_AUTH_USERS)"
echo "   - my-ai-agent/client-chat-ui/.env         (CYBERARK_*, NEXTAUTH_SECRET)"
echo "   - my-ai-agent/agent-dashboard/.env         (NEXTAUTH_SECRET, PORTKEY_*)"
echo "   - ~/mcp-secrets/{hub,memory,postgres}.env (see my-mcp-tools/mcp-hub-guide.md)"
echo "   - ~/mcp-secrets/ and its .env files should already be chmod 700/600"
read -rp "Press Enter once those are in place to continue (Ctrl+C to stop here and fill them in first)... "

# ---------------------------------------------------------------------------
# 7. Bring everything up
# ---------------------------------------------------------------------------
echo
echo "==> Starting mcp-hub"
( cd "$ROOT/my-mcp-tools/mcp-hub" && ./scripts/deploy.sh )

echo
echo "==> Starting agent-backend"
( cd "$ROOT/my-ai-agent/agent-backend" && docker compose up -d --build )

echo
echo "==> Starting client-chat-ui"
( cd "$ROOT/my-ai-agent/client-chat-ui" && docker compose up -d --build )

echo
echo "==> Starting edge-proxy"
( cd "$ROOT/edge-proxy" && docker compose up -d --build )

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
echo
echo "== Done =="
echo "Point these DNS A records at this server's public IP (Caddy can't issue certs until they resolve):"
echo "   chat.${BASE_DOMAIN}"
echo "   agent.${BASE_DOMAIN}"
echo "   dashboard.${BASE_DOMAIN}"
echo "   memory.${BASE_DOMAIN}"
echo "   memapi.${BASE_DOMAIN}"
echo "   ragui.${BASE_DOMAIN}"
echo
echo "mcp-hub's bearer-token proxy stays on http://<server-ip>:8080, reachable only from ${GATEWAY_SOURCE_IP}."
echo
if [ "$NEED_RELOGIN" -eq 1 ]; then
  echo "Reminder: log out and back in for your 'docker' group membership to take effect."
fi
echo "Re-run this script any time to update the domain, dashboard password, or gateway IP."
