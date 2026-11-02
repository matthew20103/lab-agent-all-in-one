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

# validate_dns_label LABEL -> empty stdout + exit 1 if invalid, else echoes it back.
# A DNS label: non-empty, only a-z0-9-, never starting/ending with '-', no dots.
validate_dns_label() {
  local label="$1"
  [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  printf '%s' "$label"
}

# read_masked PROMPT -> sets $MASKED_REPLY, echoing one '*' per keystroke instead of either
# the plaintext (plain `read`) or total silence (`read -s`) — a password with no feedback at
# all makes it impossible to tell a stuck terminal from a slow one, or to spot a typo before
# submitting.
read_masked() {
  local prompt="$1" char reply=''
  printf '%s' "$prompt" >&2
  while IFS= read -r -s -n1 char; do
    [ -z "$char" ] && break   # Enter: `read -n1` reads the newline as an empty $char
    if [ "$char" = $'\x7f' ] || [ "$char" = $'\b' ]; then   # Backspace/Delete
      if [ -n "$reply" ]; then
        reply="${reply%?}"
        printf '\b \b' >&2
      fi
      continue
    fi
    reply+="$char"
    printf '*' >&2
  done
  printf '\n' >&2
  MASKED_REPLY="$reply"
}

default_domain="$(existing BASE_DOMAIN "$ROOT/edge-proxy/.env")"
read -rp "Base domain, e.g. example.com [${default_domain}]: " BASE_DOMAIN
BASE_DOMAIN="${BASE_DOMAIN:-$default_domain}"
[ -n "$BASE_DOMAIN" ] || { echo "ERROR: a base domain is required." >&2; exit 1; }

# Every service here is reached by a subdomain of BASE_DOMAIN (agent./chat./... — prefixes
# chosen below), so one container calling another by that hostname needs it to actually
# resolve via real DNS.
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

# Each service is reached by its own subdomain of BASE_DOMAIN — prefixes default to the
# project's conventional names but are editable here, e.g. to avoid a clash with an existing
# hostname or to match a naming scheme already used elsewhere.
prompt_subdomain() { # prompt_subdomain VARNAME LABEL DEFAULT -> sets $VARNAME
  local __var="$1" label="$2" fallback="$3" current value
  current="$(existing "$__var" "$ROOT/edge-proxy/.env")"
  current="${current:-$fallback}"
  while true; do
    read -rp "Subdomain for $label [${current}]: " value
    value="${value:-$current}"
    value="$(printf '%s' "$value" | tr 'A-Z' 'a-z')"   # DNS is case-insensitive; normalize instead of rejecting "Chat"
    value="$(validate_dns_label "$value")" && break
    echo "ERROR: must be a valid DNS label (letters/digits/hyphens only, can't start/end with -, no dots)." >&2
  done
  printf -v "$__var" '%s' "$value"
}

prompt_subdomain CHAT_SUBDOMAIN "the chat UI" chat
prompt_subdomain AGENT_SUBDOMAIN "the backend API/WebSocket" agent
prompt_subdomain DASHBOARD_SUBDOMAIN "the admin dashboard" dashboard
prompt_subdomain MEMORY_SUBDOMAIN "the agent-memory dashboard" memory
prompt_subdomain MEMAPI_SUBDOMAIN "the agent-memory API" memapi
prompt_subdomain RAGUI_SUBDOMAIN "the knowledge-base (Chroma) UI" ragui

default_email="$(existing ACME_EMAIL "$ROOT/edge-proxy/.env")"
read -rp "Email for Let's Encrypt notifications [${default_email}]: " ACME_EMAIL
ACME_EMAIL="${ACME_EMAIL:-$default_email}"
[ -n "$ACME_EMAIL" ] || { echo "ERROR: an email is required for Let's Encrypt." >&2; exit 1; }

# Caddy always attempts its standard automatic HTTPS (HTTP-01) below — no self-signed fallback.
# That needs a real public IP with ports 80/443 reachable from the internet; if this server
# doesn't have that, automatic issuance will just keep failing/retrying harmlessly in the
# background until you run ./obtain-manual-tls-cert.sh afterward (outbound-only servers with
# DNS control get a real trusted wildcard cert via a manual DNS-01 challenge instead — see
# LAB_GUIDE.md Appendix 1.3). The DNS/TLS checks after this script brings the stack up will
# tell you which case you're in.
echo "Public Let's Encrypt (HTTP-01) needs a real public IP + inbound 80/443 reachable from the"
echo "internet. No public IP yet? Let this finish, then run ./obtain-manual-tls-cert.sh instead —"
echo "no need to answer anything differently here."

default_dash_user="$(existing DASHBOARD_USER "$ROOT/edge-proxy/.env")"
default_dash_user="${default_dash_user:-admin}"
read -rp "Admin dashboard username [${default_dash_user}]: " DASHBOARD_USER
DASHBOARD_USER="${DASHBOARD_USER:-$default_dash_user}"

existing_hash="$(unescape_dollars "$(existing DASHBOARD_PASSWORD_HASH "$ROOT/edge-proxy/.env")")"
read_masked "Admin dashboard password (leave blank to keep the existing one): "
DASHBOARD_PASSWORD="$MASKED_REPLY"
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
read_masked "MCP knowledge-base UI (ragui) password (leave blank to keep the existing one): "
MCP_UI_PASSWORD="$MASKED_REPLY"
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
read -rp "Prisma AIRS AI Gateway URL, e.g. http://<gateway-host>/v1 [${default_portkey_gw}]: " PORTKEY_GATEWAY_URL
PORTKEY_GATEWAY_URL="${PORTKEY_GATEWAY_URL:-$default_portkey_gw}"

existing_portkey_key="$(unescape_dollars "$(existing PORTKEY_API_KEY "$AGENT_ENV")")"
read_masked "Prisma AIRS AI Gateway API key (leave blank to keep the existing one): "
PORTKEY_API_KEY="${MASKED_REPLY:-$existing_portkey_key}"

default_portkey_mcp_gw="$(existing PORTKEY_MCP_GATEWAY_URL "$AGENT_ENV")"
read -rp "Prisma AIRS AI Gateway MCP gateway URL, e.g. http://<gateway-host>:8788 [${default_portkey_mcp_gw}]: " PORTKEY_MCP_GATEWAY_URL
PORTKEY_MCP_GATEWAY_URL="${PORTKEY_MCP_GATEWAY_URL:-$default_portkey_mcp_gw}"

default_portkey_slugs="$(existing PORTKEY_MCP_SERVER_SLUGS "$AGENT_ENV")"
read -rp "Prisma AIRS AI Gateway MCP server slugs, comma-separated, optional [${default_portkey_slugs}]: " PORTKEY_MCP_SERVER_SLUGS

# mem0's own OpenAI-compatible REST client needs the gateway's plain LLM API endpoint — a
# different host:port/path than PORTKEY_GATEWAY_URL above on SOME gateway setups, so it's kept
# as its own prompt rather than silently reused — but on the common setup where it's the exact
# same URL, default to what was just typed above so Enter alone repeats it instead of needing
# the whole URL retyped.
default_mem0_gw="$(existing MEM0_GATEWAY_URL "$ROOT/my-mcp-tools/mcp-hub/.env")"
default_mem0_gw="${default_mem0_gw:-$PORTKEY_GATEWAY_URL}"
read -rp "AI Gateway's LLM API URL for mem0 memory (usually same as the Prisma AIRS AI Gateway URL above) [${default_mem0_gw}]: " MEM0_GATEWAY_URL
MEM0_GATEWAY_URL="${MEM0_GATEWAY_URL:-$default_mem0_gw}"

# The exact model string your own gateway expects for this — NOT something that can have a
# working default here, since it depends entirely on how providers/virtual keys are named in
# YOUR gateway's own console. A prior hardcoded value here ("@google-vertex-sep/gemini-3.6-flash")
# only worked because that provider alias happened to exist on the original deployment's own
# gateway instance — on any other gateway it's an unrecognized provider, and mem0's calls get
# rejected outright ("Provider rejected the request as malformed"), confirmed live.
default_mem0_model="$(existing MEM0_DEFAULT_LLM_MODEL "$ROOT/my-mcp-tools/mcp-hub/.env")"
read -rp "Default LLM model for mem0 memory, e.g. gpt-4o-mini or @<your-provider-alias>/<model> if your gateway uses provider routing [${default_mem0_model}]: " MEM0_DEFAULT_LLM_MODEL
MEM0_DEFAULT_LLM_MODEL="${MEM0_DEFAULT_LLM_MODEL:-$default_mem0_model}"

# A SEPARATE model from the one above: mem0 needs a distinct embedding-capable model for
# generating vectors, not a chat/generative one — confirmed live that leaving this unset means
# mem0 reuses MEM0_DEFAULT_LLM_MODEL for embedding calls too, which fails outright
# ("is not supported in the embedContent API") if that's a chat-only model like a Gemini Pro
# variant. Give it a real embedding model from your own gateway (e.g. an OpenAI
# text-embedding-* model, or your gateway's Vertex text-embedding alias) — NOT the same value
# as above unless your gateway specifically has one model that does both.
default_mem0_embed_model="$(existing MEM0_DEFAULT_EMBEDDING_MODEL "$ROOT/my-mcp-tools/mcp-hub/.env")"
read -rp "Default EMBEDDING model for mem0 memory (must be embedding-capable, not a chat model) [${default_mem0_embed_model}]: " MEM0_DEFAULT_EMBEDDING_MODEL
MEM0_DEFAULT_EMBEDDING_MODEL="${MEM0_DEFAULT_EMBEDDING_MODEL:-$default_mem0_embed_model}"

PORTKEY_MCP_SERVER_SLUGS="${PORTKEY_MCP_SERVER_SLUGS:-$default_portkey_slugs}"

existing_basic_auth="$(unescape_dollars "$(existing BASIC_AUTH_USERS "$AGENT_ENV")")"
read -rp "BASIC_AUTH_USERS fallback login (user:bcrypt-hash,...), optional, leave blank to keep existing: " basic_auth_input
BASIC_AUTH_USERS="${basic_auth_input:-$existing_basic_auth}"

# Pre-load existing values (if any) so the "configure now?" default reflects whether this has
# already been set up on a prior run, not just whether the user happens to want to touch it now.
default_cyberark_issuer="$(existing CYBERARK_ISSUER "$AGENT_ENV")"
default_cyberark_audience="$(existing CYBERARK_AUDIENCE "$AGENT_ENV")"
default_cyberark_jwks="$(existing CYBERARK_JWKS_URI "$AGENT_ENV")"
default_cyberark_client_id="$(existing CYBERARK_USER_CLIENT_ID "$CHAT_ENV")"
existing_cyberark_secret="$(unescape_dollars "$(existing CYBERARK_USER_CLIENT_SECRET "$CHAT_ENV")")"

CYBERARK_ISSUER="$default_cyberark_issuer"
CYBERARK_AUDIENCE="$default_cyberark_audience"
CYBERARK_JWKS_URI="$default_cyberark_jwks"
CYBERARK_USER_CLIENT_ID="$default_cyberark_client_id"
CYBERARK_USER_CLIENT_SECRET="$existing_cyberark_secret"

echo
echo "==> Idira (CyberArk Identity) SSO — optional"
echo "    This lab's chat login works two ways: Basic Auth (BASIC_AUTH_USERS, above) always"
echo "    works with no setup, OR \"Sign in with Idira\" OAuth/OIDC, which needs a CyberArk"
echo "    Identity application registered in your own tenant. If you're only using Basic Auth"
echo "    for now, answer 'n' below and skip straight past this — you can always re-run"
echo "    install.sh later once Idira is set up."
echo "    If you ARE configuring Idira: in your CyberArk Identity admin console, register (or"
echo "    find) an OIDC web app for this chat UI with redirect URI:"
echo "      https://${CHAT_SUBDOMAIN}.${BASE_DOMAIN}/api/auth/callback/cyberark"
echo "    That registration gives you the Client ID/Secret below. Issuer is your tenant's OIDC"
echo "    issuer URL (serves /.well-known/openid-configuration); Audience is the API resource"
echo "    identifier Idira issues access tokens for; JWKS URI is usually that same issuer's"
echo "    own /.well-known/openid-configuration \"jwks_uri\" value."
default_configure_idira="n"
[ -n "$default_cyberark_issuer" ] && default_configure_idira="y"
read -rp "    Configure Idira SSO now? [${default_configure_idira}]: " configure_idira_input
configure_idira_input="${configure_idira_input:-$default_configure_idira}"
if [[ "$configure_idira_input" =~ ^[Yy] ]]; then
  read -rp "CyberArk Identity (Idira) issuer URL [${default_cyberark_issuer}]: " CYBERARK_ISSUER
  CYBERARK_ISSUER="${CYBERARK_ISSUER:-$default_cyberark_issuer}"

  read -rp "CyberArk Identity (Idira) audience [${default_cyberark_audience}]: " CYBERARK_AUDIENCE
  CYBERARK_AUDIENCE="${CYBERARK_AUDIENCE:-$default_cyberark_audience}"

  read -rp "CyberArk Identity (Idira) JWKS URI [${default_cyberark_jwks}]: " CYBERARK_JWKS_URI
  CYBERARK_JWKS_URI="${CYBERARK_JWKS_URI:-$default_cyberark_jwks}"

  read -rp "CyberArk Identity (Idira) chat client ID [${default_cyberark_client_id}]: " CYBERARK_USER_CLIENT_ID
  CYBERARK_USER_CLIENT_ID="${CYBERARK_USER_CLIENT_ID:-$default_cyberark_client_id}"

  read_masked "CyberArk Identity (Idira) chat client secret (leave blank to keep the existing one): "
  CYBERARK_USER_CLIENT_SECRET="${MASKED_REPLY:-$existing_cyberark_secret}"
else
  echo "    Skipping Idira SSO setup — keeping existing values untouched."
fi

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
upsert_env_var "$ROOT/edge-proxy/.env" CHAT_SUBDOMAIN "$CHAT_SUBDOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" AGENT_SUBDOMAIN "$AGENT_SUBDOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" DASHBOARD_SUBDOMAIN "$DASHBOARD_SUBDOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" MEMORY_SUBDOMAIN "$MEMORY_SUBDOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" MEMAPI_SUBDOMAIN "$MEMAPI_SUBDOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" RAGUI_SUBDOMAIN "$RAGUI_SUBDOMAIN"
upsert_env_var "$ROOT/edge-proxy/.env" ACME_EMAIL "$ACME_EMAIL"
upsert_env_var "$ROOT/edge-proxy/.env" DASHBOARD_USER "$DASHBOARD_USER"
upsert_env_var "$ROOT/edge-proxy/.env" DASHBOARD_PASSWORD_HASH "$(escape_dollars "$DASHBOARD_PASSWORD_HASH")"
upsert_env_var "$ROOT/edge-proxy/.env" MCP_UI_USER "$MCP_UI_USER"
upsert_env_var "$ROOT/edge-proxy/.env" MCP_UI_PASSWORD_HASH "$(escape_dollars "$MCP_UI_PASSWORD_HASH")"

# edge-proxy/docker-compose.yml bind-mounts both of these — they must exist before `docker
# compose up` runs, even for servers that never run obtain-manual-tls-cert.sh. Never clobber
# tls-override.conf if it's already been populated by that script (a real cert is in use). If
# Docker ever started edge-proxy before this file existed, it silently created it as a
# DIRECTORY instead (Docker's bind-mount behavior for a missing source) — which then makes
# Caddy fail to parse `import tls-override.conf` and crash-loop. Self-heal that case too. No
# sudo needed: removing an empty directory only needs write+execute on its PARENT
# (edge-proxy/, owned by this user), not root, regardless of who/what created the entry.
if [ -d "$ROOT/edge-proxy/tls-override.conf" ]; then
  echo "==> fixing edge-proxy/tls-override.conf (Docker created it as a directory, not a file)"
  rmdir "$ROOT/edge-proxy/tls-override.conf"
fi
[ -f "$ROOT/edge-proxy/tls-override.conf" ] || : > "$ROOT/edge-proxy/tls-override.conf"
sudo mkdir -p /etc/letsencrypt

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
upsert_env_var "$AGENT_ENV" CORS_ALLOWED_ORIGINS "https://${CHAT_SUBDOMAIN}.${BASE_DOMAIN},https://${DASHBOARD_SUBDOMAIN}.${BASE_DOMAIN}"
# agent-backend/docker-compose.yml's own dashboard service reads this to build its NEXTAUTH_URL.
upsert_env_var "$AGENT_ENV" DASHBOARD_SUBDOMAIN "$DASHBOARD_SUBDOMAIN"

# NEXT_PUBLIC_AGENT_BASE_URL must be a BARE host[:port], no scheme — client-chat-ui's own
# src/lib/constants.ts prepends "wss://"/"https://" itself (AGENT_WSS_URL = `wss://${AGENT_BASE_URL}/ws`,
# etc.). Setting this to a full URL (e.g. "https://agent.${BASE_DOMAIN}") produces a
# double-scheme string that the WHATWG URL parser mangles into "wss://https//agent.../ws"
# (the first "https" becomes an empty-port host, swallowing a "/" from "//" into the path) —
# a real bug this project hit, not a hypothetical one. Keep this scheme-less.
upsert_env_var "$CHAT_ENV" NEXT_PUBLIC_AGENT_BASE_URL "${AGENT_SUBDOMAIN}.${BASE_DOMAIN}"
upsert_env_var "$CHAT_ENV" NEXTAUTH_URL "https://${CHAT_SUBDOMAIN}.${BASE_DOMAIN}"
upsert_env_var "$CHAT_ENV" CYBERARK_ISSUER "$CYBERARK_ISSUER"
upsert_env_var "$CHAT_ENV" CYBERARK_USER_CLIENT_ID "$CYBERARK_USER_CLIENT_ID"
upsert_env_var "$CHAT_ENV" CYBERARK_USER_CLIENT_SECRET "$(escape_dollars "$CYBERARK_USER_CLIENT_SECRET")"
# Read client-side (src/app/auth/signin/page.tsx) to decide whether to show the "Sign in with
# Idira" button at all — must match src/lib/auth.ts's own idiraConfigured check (both keyed off
# CYBERARK_ISSUER being set), or the button could be shown/hidden out of sync with whether the
# provider is actually registered server-side.
upsert_env_var "$CHAT_ENV" NEXT_PUBLIC_IDIRA_ENABLED "$([ -n "$CYBERARK_ISSUER" ] && echo true || echo false)"
upsert_env_var "$CHAT_ENV" NEXTAUTH_SECRET "$CHAT_NEXTAUTH_SECRET"

upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" BASE_DOMAIN "$BASE_DOMAIN"
upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" MEMORY_SUBDOMAIN "$MEMORY_SUBDOMAIN"
upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" MEMAPI_SUBDOMAIN "$MEMAPI_SUBDOMAIN"
upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" MEM0_GATEWAY_URL "$MEM0_GATEWAY_URL"
upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" MEM0_DEFAULT_LLM_MODEL "$MEM0_DEFAULT_LLM_MODEL"
upsert_env_var "$ROOT/my-mcp-tools/mcp-hub/.env" MEM0_DEFAULT_EMBEDDING_MODEL "$MEM0_DEFAULT_EMBEDDING_MODEL"

chmod 600 "$ROOT/edge-proxy/.env" "$AGENT_ENV" "$CHAT_ENV" "$ROOT/my-mcp-tools/mcp-hub/.env"

echo
echo "==> Checking for still-empty required values"
# CyberArk/Idira fields are intentionally excluded here — they're optional (Basic Auth works
# standalone with zero Idira config; see the "Configure Idira SSO now?" prompt above), so an
# empty value there is a deliberate choice, not something to warn about.
for pair in \
  "PORTKEY_API_KEY:$PORTKEY_API_KEY" \
  "MEM0_GATEWAY_URL:$MEM0_GATEWAY_URL" \
  "MEM0_DEFAULT_LLM_MODEL:$MEM0_DEFAULT_LLM_MODEL" \
  "MEM0_DEFAULT_EMBEDDING_MODEL:$MEM0_DEFAULT_EMBEDDING_MODEL" \
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
  read_masked "AI Gateway API key for mem0 memory (leave blank to reuse the Prisma AIRS AI Gateway API key above): "
  memory_gateway_key="${MASKED_REPLY:-$PORTKEY_API_KEY}"
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

ALL_SUBDOMAINS=("$CHAT_SUBDOMAIN" "$AGENT_SUBDOMAIN" "$DASHBOARD_SUBDOMAIN" "$MEMORY_SUBDOMAIN" "$MEMAPI_SUBDOMAIN" "$RAGUI_SUBDOMAIN")

# Real Let's Encrypt (HTTP-01) can only ever succeed once DNS actually points each hostname at
# this server's PUBLIC IP — not the private/LAN IP install.sh itself runs on if this box sits
# behind NAT (a cloud instance's own `ip route get` src IP is very often its private IP, not
# its public/elastic one). This is best-effort and non-blocking: DNS propagation lag is normal,
# and a server with no inbound connectivity at all is an expected, supported case (see
# obtain-manual-tls-cert.sh below) — so a mismatch here is a heads-up, not a hard failure.
# `getent` needs no extra package, unlike `dig`, which isn't installed by default on a minimal
# Ubuntu image.
echo
echo "==> Checking DNS before requesting real certificates"
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [ -n "$PUBLIC_IP" ]; then
  echo "   this server's public IP looks like: $PUBLIC_IP"
  for sub in "${ALL_SUBDOMAINS[@]}"; do
    fqdn="${sub}.${BASE_DOMAIN}"
    resolved="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}')"
    if [ "$resolved" != "$PUBLIC_IP" ]; then
      echo "   WARNING: ${fqdn} resolves to '${resolved:-nothing}', not ${PUBLIC_IP} yet." >&2
      echo "            Point its DNS A record here before/while Caddy requests a cert — it" >&2
      echo "            will keep retrying ACME in the background either way. If this server" >&2
      echo "            has no inbound 80/443 at all, ignore this and run" >&2
      echo "            ./obtain-manual-tls-cert.sh once the stack is up instead." >&2
    fi
  done
else
  echo "   couldn't determine this server's public IP (offline, or api.ipify.org unreachable) — skipping"
fi

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

# Confirm Caddy actually obtained real certs instead of leaving the user to guess — ACME's
# HTTP-01 round trip isn't instant, so poll for up to a minute before calling it failed. A
# FAILED here is expected (not a bug) for a server with no inbound 80/443 at all — that's what
# obtain-manual-tls-cert.sh is for. Checked in PARALLEL (one background job per subdomain) since
# six sequential ~1-minute timeouts (worst case: no inbound connectivity, so EVERY one times
# out) made this take up to 12 minutes. Ask instead of requiring an env var to skip it —
# nothing to remember, just answer "n" when you already know this server has no inbound
# connectivity and are going straight to obtain-manual-tls-cert.sh anyway.
echo
read -rp "Verify TLS certificates now (up to ~1 minute)? [Y/n]: " verify_tls_input
if [[ "$verify_tls_input" =~ ^[Nn] ]]; then
  echo "==> Skipping TLS certificate verification"
else
  echo "==> Verifying TLS certificates (parallel, up to ~1 minute)"
  tls_check_pids=()
  for sub in "${ALL_SUBDOMAINS[@]}"; do
    (
      fqdn="${sub}.${BASE_DOMAIN}"
      ok=0
      for _ in $(seq 1 12); do
        if curl -fsS --max-time 5 "https://${fqdn}" -o /dev/null 2>/dev/null; then ok=1; break; fi
        sleep 5
      done
      if [ "$ok" -eq 1 ]; then
        printf '   OK: https://%s\n' "$fqdn"
      else
        printf '   FAILED: https://%s — if this server has no inbound 80/443 at all, that'"'"'s
            expected: run ./obtain-manual-tls-cert.sh once this script finishes.
            Otherwise check: does its DNS A record point here yet? are ports 80/443
            reachable from the public internet (cloud provider firewall/security
            group, not just ufw)? Full error:
            (cd edge-proxy && docker compose logs edge-proxy --tail 50)\n' "$fqdn" >&2
      fi
    ) &
    tls_check_pids+=("$!")
  done
  for pid in "${tls_check_pids[@]}"; do wait "$pid"; done
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo
echo "== Done =="
echo "Point these DNS A records at this server's public IP (Caddy can't issue real certs until"
echo "they resolve — or skip that and run ./obtain-manual-tls-cert.sh if this server has no"
echo "inbound 80/443 at all, see LAB_GUIDE.md Appendix 1.3):"
for sub in "${ALL_SUBDOMAINS[@]}"; do
  echo "   ${sub}.${BASE_DOMAIN}"
done
echo
echo "mcp-hub's bearer-token proxy stays on http://<server-ip>:8080, reachable only from ${GATEWAY_SOURCE_IP}."
echo
echo "MCP server slugs available to add in the dashboard's MCP Servers tab (must match exactly,"
echo "case-sensitive — these come straight from mcp-hub's own compose.yaml, so this list always"
echo "reflects whatever's actually registered there):"
# grep exits 1 (not an error here, just "no matches") if mcp-hub's compose.yaml ever has no
# `include:` entries — under `set -euo pipefail` that would otherwise silently kill the WHOLE
# script at this exact line, before the "Done"/DNS-record summary below even prints. `|| true`
# makes an empty result list, not a crash.
mcp_slugs="$(grep -oE 'servers/[a-zA-Z0-9_-]+/compose\.yaml' "$ROOT/my-mcp-tools/mcp-hub/compose.yaml" \
  | sed -E 's#servers/([a-zA-Z0-9_-]+)/compose\.yaml#   \1#' || true)"
if [ -n "$mcp_slugs" ]; then
  echo "$mcp_slugs"
else
  echo "   (couldn't read any from my-mcp-tools/mcp-hub/compose.yaml — check it by hand)"
fi
echo "Each one's bearer token lives in ~/mcp-secrets/hub.env (MCP_TOKEN_<NAME>, auto-generated —"
echo "see LAB_GUIDE.md Appendix 3 for the full per-tool reference)."
echo
if [ "$NEED_RELOGIN" -eq 1 ]; then
  echo "Reminder: log out and back in for your 'docker' group membership to take effect."
fi
echo "Re-run this script any time to update the domain, dashboard password, or gateway IP."
