#!/usr/bin/env bash
# All-in-a-box installer: brings up client-chat-ui, agent-backend, mcp-hub and edge-proxy
# on a single, brand-new Ubuntu server. Checks/installs prerequisites, interactively asks
# for the public domain AND every business secret (Portkey, CyberArk Identity/Idira, mem0's
# AI Gateway key), wires every project's config to it, sets up the firewall, then starts
# everything. Safe to re-run (idempotent): re-running shows prior answers as defaults, and
# blank input keeps whatever's already configured.
#
# Run as a normal sudo-capable user, NOT as root and NOT with `sudo ./install.sh` — the
# script calls sudo itself for the privileged steps (apt, ufw, iptables, sysctl, usermod).
# Docker Compose must run as your own user so files under ~/mcp-secrets/ stay owned by you
# (mcp-hub/scripts/deploy.sh already enforces this and will refuse to run otherwise).
#
# Assumes this whole project folder is already on the server (e.g. copied over with
# `rsync`/`scp` — see LAB_GUIDE.md section E).

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

# `dpkg -s <pkg>` returns success even for a package that was later removed but left its
# config files behind ("deinstall ok config-files") — it only fails if dpkg has never heard
# of the package at all. That false positive is exactly how a pre-removed `ufw` slips past a
# naive check. Match the actual install status instead.
is_pkg_installed() {
  [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]
}

ensure_apt_pkg() {
  local pkg="$1"
  if ! is_pkg_installed "$pkg"; then
    echo "   installing $pkg"
    sudo apt-get install -y "$pkg"
  fi
}

NEED_APT_UPDATE=0
for pkg in ca-certificates curl openssl ufw; do
  is_pkg_installed "$pkg" || NEED_APT_UPDATE=1
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

# Being listed in the docker group (checked above) and this *session* actually having that
# group active are two different things — a session started before the usermod won't pick it
# up until a new login (or an explicit group switch). `newgrp docker` can't be used here: it
# execs into a brand-new shell and never returns, so nothing after it in this script would run.
# `sg docker -c '<command>'` is the non-interactive equivalent — it runs one command with the
# docker group active without replacing the session — so on a mismatch, relaunch this whole
# script through it once, automatically, instead of making you log out and back in by hand.
if ! docker info >/dev/null 2>&1; then
  if [ "${AIAO_REEXEC_DOCKER_GROUP:-0}" = "1" ]; then
    echo "ERROR: still can't talk to Docker after relaunching via 'sg docker'." >&2
    echo "Log out and SSH back in (a fresh session, not just a new tab), then re-run ./install.sh." >&2
    exit 1
  fi
  if ! command -v sg >/dev/null 2>&1; then
    echo "ERROR: can't talk to Docker (permission denied), and 'sg' isn't available to work around it." >&2
    echo "Log out and SSH back in, then re-run ./install.sh." >&2
    exit 1
  fi
  echo "   docker group membership isn't active in this shell yet — relaunching via 'sg docker' (no logout needed)"
  export AIAO_REEXEC_DOCKER_GROUP=1
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

# ---------------------------------------------------------------------------
# 3. Prompts
# ---------------------------------------------------------------------------
echo
echo "==> Configuration"

existing() { # existing KEY FILE -> prints current value or empty
  [ -f "$2" ] && grep -E "^${1}=" "$2" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# agent-backend/.env, client-chat-ui/.env and edge-proxy/.env are all referenced via
# `${VAR}` in their respective docker-compose.yml `environment:` lists — which means Compose
# interpolates their *values*, not just substitutes them verbatim. A bcrypt hash (always
# contains literal `$`) or any other secret that happens to contain `$` gets silently mangled:
# Compose reads e.g. `$2b$10$H21b92H5x6o8SOb69JBHT...`, treats `$H21b92H5x6o8SOb69JBHT` as an
# undefined variable reference, and blanks that chunk out. Compose's documented escape for a
# literal `$` is `$$` — apply it at write time, reverse it when reading a value back as a
# "keep existing" default, so re-running this script doesn't double-escape.
escape_dollars() { printf '%s' "${1//\$/\$\$}"; }
unescape_dollars() { printf '%s' "${1//\$\$/\$}"; }

default_domain="$(existing BASE_DOMAIN "$ROOT/edge-proxy/.env")"
read -rp "Base domain, e.g. example.com [${default_domain}]: " BASE_DOMAIN
BASE_DOMAIN="${BASE_DOMAIN:-$default_domain}"
[ -n "$BASE_DOMAIN" ] || { echo "ERROR: a base domain is required." >&2; exit 1; }

# Every service here is reached by subdomain (agent.${BASE_DOMAIN}, chat.${BASE_DOMAIN}, ...),
# so one container calling another by that hostname needs it to actually resolve via real DNS.
# .local/.test/.example/.invalid/.localhost/.internal are reserved special-use names that are
# GUARANTEED to never resolve that way (.local specifically needs mDNS, which doesn't work from
# inside a Docker container at all; the others are reserved by IANA so they're never delegated)
# — confirmed twice in the field as students picked one of these, got EAI_AGAIN/ENOTFOUND deep
# in a container's auth logs, and it surfaced only later as a confusing "wrong password" error.
# Fail fast here instead, with the actual fix, rather than let that happen again.
case ".${BASE_DOMAIN}." in
  *.local.|*.test.|*.example.|*.invalid.|*.localhost.|*.internal.)
    detected_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
    echo "ERROR: '${BASE_DOMAIN}' ends in a reserved/special-use name that will NEVER resolve" >&2
    echo "       via real DNS, even though it may resolve on your own machine right now." >&2
    echo "       No real domain yet? Use nip.io instead — a free wildcard DNS service that" >&2
    echo "       resolves ANY hostname with an IP embedded (dashes, not dots) straight to that" >&2
    echo "       IP, with zero setup, and works correctly from inside containers. Try:" >&2
    if [ -n "$detected_ip" ]; then
      echo "         ${detected_ip//./-}.nip.io" >&2
    else
      echo "         <this-server's-ip-with-dashes-instead-of-dots>.nip.io" >&2
    fi
    exit 1
    ;;
esac

default_email="$(existing ACME_EMAIL "$ROOT/edge-proxy/.env")"
read -rp "Email for Let's Encrypt notifications [${default_email}]: " ACME_EMAIL
ACME_EMAIL="${ACME_EMAIL:-$default_email}"
[ -n "$ACME_EMAIL" ] || { echo "ERROR: an email is required for Let's Encrypt." >&2; exit 1; }

# Public Let's Encrypt/ZeroSSL validation can only ever reach a server at a real public IP.
# A private-network test box (e.g. 192.168.x.x/10.x.x.x) will always fail with a DNS-looking
# error ("no valid A records found") that's actually a reachability problem, not a DNS one —
# and repeated attempts can trip Let's Encrypt's rate limiter for up to an hour. So default to
# the SAFE answer ("n") whenever this hasn't been explicitly answered before; only default to
# "y" if a previous run's answer is actually on record (grep for the key, not just its value —
# an explicit prior "public" answer is stored as an empty value, indistinguishable from
# "never asked" if we only looked at the resolved value).
if grep -qE "^CADDY_LOCAL_CERTS=" "$ROOT/edge-proxy/.env" 2>/dev/null; then
  if [ "$(existing CADDY_LOCAL_CERTS "$ROOT/edge-proxy/.env")" = "local_certs" ]; then
    default_public_reachable="n"
  else
    default_public_reachable="y"
  fi
else
  default_public_reachable="n"
fi
read -rp "Is this server reachable from the public internet on ports 80/443 (a real public IP, not a private 192.168.x.x/10.x.x.x one)? [${default_public_reachable}]: " public_reachable_input
public_reachable_input="${public_reachable_input:-$default_public_reachable}"
if [[ "$public_reachable_input" =~ ^[Yy] ]]; then
  CADDY_LOCAL_CERTS=""
else
  CADDY_LOCAL_CERTS="local_certs"
  echo "   Using Caddy's internal CA (self-signed-style certs) instead of public Let's Encrypt —"
  echo "   browsers will warn \"not trusted\" and curl needs -k/--insecure until this server is"
  echo "   publicly reachable and you re-run this script answering \"y\" here."
fi

default_dash_user="$(existing DASHBOARD_USER "$ROOT/edge-proxy/.env")"
default_dash_user="${default_dash_user:-admin}"
read -rp "Admin dashboard username [${default_dash_user}]: " DASHBOARD_USER
DASHBOARD_USER="${DASHBOARD_USER:-$default_dash_user}"

existing_hash="$(unescape_dollars "$(existing DASHBOARD_PASSWORD_HASH "$ROOT/edge-proxy/.env")")"
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

existing_mcp_ui_hash="$(unescape_dollars "$(existing MCP_UI_PASSWORD_HASH "$ROOT/edge-proxy/.env")")"
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
# 3b. Business secrets (Portkey, CyberArk Identity/Idira, mem0's AI Gateway key).
#     Blank input keeps whatever's already in the .env file; nothing here is invented.
# ---------------------------------------------------------------------------
echo
echo "==> Business secrets (press Enter on any prompt to keep its current value)"

AGENT_ENV="$ROOT/my-ai-agent/agent-backend/.env"
CHAT_ENV="$ROOT/my-ai-agent/client-chat-ui/.env"

default_portkey_gw="$(existing PORTKEY_GATEWAY_URL "$AGENT_ENV")"
read -rp "Portkey gateway URL [${default_portkey_gw}]: " PORTKEY_GATEWAY_URL
PORTKEY_GATEWAY_URL="${PORTKEY_GATEWAY_URL:-$default_portkey_gw}"

existing_portkey_key="$(unescape_dollars "$(existing PORTKEY_API_KEY "$AGENT_ENV")")"
read -rsp "Portkey API key (leave blank to keep the existing one): " portkey_key_input
echo
PORTKEY_API_KEY="${portkey_key_input:-$existing_portkey_key}"

default_portkey_mcp_gw="$(existing PORTKEY_MCP_GATEWAY_URL "$AGENT_ENV")"
read -rp "Portkey MCP gateway URL [${default_portkey_mcp_gw}]: " PORTKEY_MCP_GATEWAY_URL
PORTKEY_MCP_GATEWAY_URL="${PORTKEY_MCP_GATEWAY_URL:-$default_portkey_mcp_gw}"

default_portkey_slugs="$(existing PORTKEY_MCP_SERVER_SLUGS "$AGENT_ENV")"
read -rp "Portkey MCP server slugs, comma-separated, optional [${default_portkey_slugs}]: " PORTKEY_MCP_SERVER_SLUGS

# mem0's own OpenAI-compatible REST client needs the gateway's plain LLM API endpoint — a
# different host:port/path than PORTKEY_GATEWAY_URL above on some gateway setups, so it's its
# own prompt rather than reused.
default_mem0_gw="$(existing MEM0_GATEWAY_URL "$ROOT/my-mcp-tools/mcp-hub/.env")"
read -rp "AI Gateway's LLM API URL for mem0 memory, e.g. http://<gateway-host>/v1 [${default_mem0_gw}]: " MEM0_GATEWAY_URL
MEM0_GATEWAY_URL="${MEM0_GATEWAY_URL:-$default_mem0_gw}"
PORTKEY_MCP_SERVER_SLUGS="${PORTKEY_MCP_SERVER_SLUGS:-$default_portkey_slugs}"

existing_basic_auth="$(unescape_dollars "$(existing BASIC_AUTH_USERS "$AGENT_ENV")")"
read -rp "BASIC_AUTH_USERS fallback login (user:bcrypt-hash,...), optional, leave blank to keep existing: " basic_auth_input
BASIC_AUTH_USERS="${basic_auth_input:-$existing_basic_auth}"

default_cyberark_issuer="$(existing CYBERARK_ISSUER "$AGENT_ENV")"
read -rp "CyberArk Identity (Idira) issuer URL [${default_cyberark_issuer}]: " CYBERARK_ISSUER
CYBERARK_ISSUER="${CYBERARK_ISSUER:-$default_cyberark_issuer}"

default_cyberark_audience="$(existing CYBERARK_AUDIENCE "$AGENT_ENV")"
read -rp "CyberArk Identity (Idira) audience [${default_cyberark_audience}]: " CYBERARK_AUDIENCE
CYBERARK_AUDIENCE="${CYBERARK_AUDIENCE:-$default_cyberark_audience}"

default_cyberark_jwks="$(existing CYBERARK_JWKS_URI "$AGENT_ENV")"
read -rp "CyberArk Identity (Idira) JWKS URI [${default_cyberark_jwks}]: " CYBERARK_JWKS_URI
CYBERARK_JWKS_URI="${CYBERARK_JWKS_URI:-$default_cyberark_jwks}"

default_cyberark_client_id="$(existing CYBERARK_USER_CLIENT_ID "$CHAT_ENV")"
read -rp "CyberArk Identity (Idira) chat client ID [${default_cyberark_client_id}]: " CYBERARK_USER_CLIENT_ID
CYBERARK_USER_CLIENT_ID="${CYBERARK_USER_CLIENT_ID:-$default_cyberark_client_id}"

existing_cyberark_secret="$(unescape_dollars "$(existing CYBERARK_USER_CLIENT_SECRET "$CHAT_ENV")")"
read -rsp "CyberArk Identity (Idira) chat client secret (leave blank to keep the existing one): " cyberark_secret_input
echo
CYBERARK_USER_CLIENT_SECRET="${cyberark_secret_input:-$existing_cyberark_secret}"

# NEXTAUTH_SECRET is a local signing key, not an external credential — generate one per app
# instead of prompting, same as any other secret with no external system to match it against.
BACKEND_NEXTAUTH_SECRET="$(existing NEXTAUTH_SECRET "$AGENT_ENV")"
BACKEND_NEXTAUTH_SECRET="${BACKEND_NEXTAUTH_SECRET:-$(openssl rand -base64 32)}"
CHAT_NEXTAUTH_SECRET="$(existing NEXTAUTH_SECRET "$CHAT_ENV")"
CHAT_NEXTAUTH_SECRET="${CHAT_NEXTAUTH_SECRET:-$(openssl rand -base64 32)}"

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
upsert_env_var "$ROOT/edge-proxy/.env" DASHBOARD_PASSWORD_HASH "$(escape_dollars "$DASHBOARD_PASSWORD_HASH")"
upsert_env_var "$ROOT/edge-proxy/.env" MCP_UI_USER "$MCP_UI_USER"
upsert_env_var "$ROOT/edge-proxy/.env" MCP_UI_PASSWORD_HASH "$(escape_dollars "$MCP_UI_PASSWORD_HASH")"
upsert_env_var "$ROOT/edge-proxy/.env" CADDY_LOCAL_CERTS "$CADDY_LOCAL_CERTS"

upsert_env_var "$AGENT_ENV" BASE_DOMAIN "$BASE_DOMAIN"
upsert_env_var "$AGENT_ENV" PORTKEY_GATEWAY_URL "$PORTKEY_GATEWAY_URL"
upsert_env_var "$AGENT_ENV" PORTKEY_API_KEY "$(escape_dollars "$PORTKEY_API_KEY")"
upsert_env_var "$AGENT_ENV" PORTKEY_MCP_GATEWAY_URL "$PORTKEY_MCP_GATEWAY_URL"
upsert_env_var "$AGENT_ENV" PORTKEY_MCP_SERVER_SLUGS "$PORTKEY_MCP_SERVER_SLUGS"
upsert_env_var "$AGENT_ENV" BASIC_AUTH_USERS "$(escape_dollars "$BASIC_AUTH_USERS")"
upsert_env_var "$AGENT_ENV" CYBERARK_ISSUER "$CYBERARK_ISSUER"
upsert_env_var "$AGENT_ENV" CYBERARK_AUDIENCE "$CYBERARK_AUDIENCE"
upsert_env_var "$AGENT_ENV" CYBERARK_JWKS_URI "$CYBERARK_JWKS_URI"
upsert_env_var "$AGENT_ENV" NEXTAUTH_SECRET "$BACKEND_NEXTAUTH_SECRET"
# The chat UI and admin dashboard call the backend's API cross-origin from the browser (two
# different hostnames), so FastAPI's CORSMiddleware needs both explicitly allow-listed —
# derived from BASE_DOMAIN so this doesn't silently break on the next domain change the way
# the old hardcoded matthewwan.dev origins just did.
upsert_env_var "$AGENT_ENV" CORS_ALLOWED_ORIGINS "https://chat.${BASE_DOMAIN},https://dashboard.${BASE_DOMAIN}"

# NEXT_PUBLIC_AGENT_BASE_URL must be a BARE host[:port], no scheme — client-chat-ui's own
# src/lib/constants.ts prepends "wss://"/"https://" itself (AGENT_WSS_URL = `wss://${AGENT_BASE_URL}/ws`,
# etc.). Setting this to a full URL (e.g. "https://agent.${BASE_DOMAIN}") produces a
# double-scheme string that the WHATWG URL parser mangles into "wss://https//agent.../ws"
# (the first "https" becomes an empty-port host, swallowing a "/" from "//" into the path) —
# a real bug this project hit, not a hypothetical one. Keep this scheme-less.
upsert_env_var "$CHAT_ENV" NEXT_PUBLIC_AGENT_BASE_URL "agent.${BASE_DOMAIN}"
upsert_env_var "$CHAT_ENV" NEXTAUTH_URL "https://chat.${BASE_DOMAIN}"
upsert_env_var "$CHAT_ENV" CYBERARK_ISSUER "$CYBERARK_ISSUER"
upsert_env_var "$CHAT_ENV" CYBERARK_USER_CLIENT_ID "$CYBERARK_USER_CLIENT_ID"
upsert_env_var "$CHAT_ENV" CYBERARK_USER_CLIENT_SECRET "$(escape_dollars "$CYBERARK_USER_CLIENT_SECRET")"
upsert_env_var "$CHAT_ENV" NEXTAUTH_SECRET "$CHAT_NEXTAUTH_SECRET"

upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" BASE_DOMAIN "$BASE_DOMAIN"
upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" MEM0_GATEWAY_URL "$MEM0_GATEWAY_URL"

chmod 600 "$ROOT/edge-proxy/.env" "$AGENT_ENV" "$CHAT_ENV" "$ROOT/my-mcp-tools/mcp-hub/.env"

echo
echo "==> Checking for still-empty required values"
for pair in \
  "PORTKEY_API_KEY:$PORTKEY_API_KEY" \
  "CYBERARK_ISSUER:$CYBERARK_ISSUER" \
  "CYBERARK_AUDIENCE:$CYBERARK_AUDIENCE" \
  "CYBERARK_JWKS_URI:$CYBERARK_JWKS_URI" \
  "CYBERARK_USER_CLIENT_ID:$CYBERARK_USER_CLIENT_ID" \
  "CYBERARK_USER_CLIENT_SECRET:$CYBERARK_USER_CLIENT_SECRET" \
  "MEM0_GATEWAY_URL:$MEM0_GATEWAY_URL" \
; do
  name="${pair%%:*}"
  val="${pair#*:}"
  [ -n "$val" ] || echo "   WARNING: $name is still empty — the app may not fully start until it's set (re-run this script to fill it in)."
done

# ---------------------------------------------------------------------------
# 4b. mcp-hub's own per-server secrets (~/mcp-secrets/, outside the repo, same convention
#     mcp-hub already used standalone — hub.env is handled automatically by its own
#     scripts/deploy.sh in step 6 below, so only memory.env/postgres.env need creating here).
# ---------------------------------------------------------------------------
echo
echo "==> mcp-hub secrets (~/mcp-secrets/)"

MCP_SECRETS_DIR="$HOME/mcp-secrets"
mkdir -p "$MCP_SECRETS_DIR"
chmod 700 "$MCP_SECRETS_DIR"

if [ -f "$MCP_SECRETS_DIR/memory.env" ]; then
  echo "   ~/mcp-secrets/memory.env already exists — leaving it as-is."
else
  read -rsp "AI Gateway API key for mem0 memory (leave blank to reuse the Portkey API key above): " memory_gateway_key_input
  echo
  memory_gateway_key="${memory_gateway_key_input:-$PORTKEY_API_KEY}"
  if [ -n "$memory_gateway_key" ]; then
    ( umask 077
      printf '%s\n' \
        "POSTGRES_USER=postgres" \
        "POSTGRES_PASSWORD=$(openssl rand -hex 16)" \
        "JWT_SECRET=$(openssl rand -hex 32)" \
        "ADMIN_API_KEY=$(openssl rand -hex 32)" \
        "OPENAI_API_KEY=$memory_gateway_key" \
        > "$MCP_SECRETS_DIR/memory.env" )
    echo "   created ~/mcp-secrets/memory.env"
  else
    echo "   WARNING: no AI Gateway API key given — skipped. The memory MCP server won't start"
    echo "   until ~/mcp-secrets/memory.env is created (re-run this script to create it)."
  fi
fi

if [ -f "$MCP_SECRETS_DIR/postgres.env" ]; then
  echo "   ~/mcp-secrets/postgres.env already exists — leaving it as-is."
else
  ( umask 077
    printf '%s\n' \
      "POSTGRES_USER=postgres" \
      "POSTGRES_DB=demo" \
      "POSTGRES_PASSWORD=$(openssl rand -hex 16)" \
      "AGENT_RO_PASSWORD=$(openssl rand -hex 16)" \
      "AGENT_RW_PASSWORD=$(openssl rand -hex 16)" \
      > "$MCP_SECRETS_DIR/postgres.env" )
  echo "   created ~/mcp-secrets/postgres.env"
fi

# ---------------------------------------------------------------------------
# 5. Firewall
# ---------------------------------------------------------------------------
echo
echo "==> Firewall"

sudo ufw allow OpenSSH >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null

# Docker-published ports bypass ufw entirely, so the MCP hub's bearer-token proxy (8080) is
# restricted directly in the DOCKER-USER chain instead (see LAB_GUIDE.md section D.4) — but
# persisted via a small systemd unit rather than the `iptables-persistent` package, which
# actively Conflicts/Replaces `ufw` on Ubuntu 24.04 (installing one removes the other).
#
# Scoped with --ctorigdst to this server's own IP, not just --ctorigdstport 8080 alone —
# confirmed via packet trace on a live deployment: matching on port number alone also catches
# any OTHER container's own outbound connections to port 8080 on a completely different host
# (e.g. agent-backend calling an AI Gateway that happens to expose something on port 8080
# too), silently dropping traffic that has nothing to do with mcp-hub at all. --ctorigdst
# tracks the connection's pre-DNAT destination, so it stays correct even though inbound
# traffic to mcp-hub has its destination rewritten to the container's own IP by the time this
# chain evaluates it.
SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
[ -n "$SERVER_IP" ] || { echo "ERROR: couldn't auto-detect this server's own LAN IP (ip route get 1.1.1.1)." >&2; exit 1; }
DOCKER_USER_RULE="iptables -C DOCKER-USER -p tcp -m conntrack --ctorigdstport 8080 --ctorigdst ${SERVER_IP} ! -s ${GATEWAY_SOURCE_IP} -j DROP 2>/dev/null || iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 8080 --ctorigdst ${SERVER_IP} ! -s ${GATEWAY_SOURCE_IP} -j DROP"

# Must be evaluated BEFORE the DROP rule above (confirmed via packet trace on a live
# deployment): a published-port connection's reply traffic isn't un-DNAT'd before
# DOCKER-USER sees it, so the reply packet still shows the container's raw (non-gateway)
# address at this point. Without this ACCEPT, the DROP rule above matches the reply itself,
# not just unwanted new connections — so the AI Gateway's own requests would connect, get a
# response from mcp-hub, and then hang forever waiting for a reply that gets silently
# dropped on the way back out. Since both rules insert at the head of the chain, running this
# AFTER the DROP rule's setup is what puts it first.
ESTABLISHED_RULE="iptables -C DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

sudo sh -c "$DOCKER_USER_RULE"
sudo sh -c "$ESTABLISHED_RULE"

sudo tee /etc/systemd/system/agent-all-in-one-docker-user.service >/dev/null <<EOF
[Unit]
Description=Restrict mcp-hub port 8080 in Docker's DOCKER-USER chain to the AI Gateway
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${DOCKER_USER_RULE} && ${ESTABLISHED_RULE}'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now agent-all-in-one-docker-user.service >/dev/null

echo "   ufw: 22, 80, 443 allowed; port 8080 restricted to ${GATEWAY_SOURCE_IP} via DOCKER-USER (persisted by systemd, not iptables-persistent)"

# ---------------------------------------------------------------------------
# 6. Bring everything up
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
# 7. Summary
# ---------------------------------------------------------------------------
echo
echo "== Done =="
if [ -n "$CADDY_LOCAL_CERTS" ]; then
  echo "TLS: using Caddy's internal CA (self-signed-style certs) — this server isn't marked"
  echo "public-reachable. Browsers will warn \"not trusted\"; curl needs -k/--insecure. Re-run"
  echo "this script and answer \"y\" to the public-reachability prompt once that's no longer true."
else
  echo "Point these DNS A records at this server's public IP (Caddy can't issue certs until they resolve):"
fi
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
