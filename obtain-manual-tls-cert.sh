#!/usr/bin/env bash
# Gets a real, publicly-trusted wildcard TLS cert for *.{BASE_DOMAIN} via a MANUAL Let's
# Encrypt DNS-01 challenge, and wires edge-proxy (Caddy) to use it instead of install.sh's
# default automatic Let's Encrypt (HTTP-01). For servers with outbound-only connectivity — no
# inbound 80/443 reachable from the public internet at all, so HTTP-01 can never succeed
# regardless of DNS — but full control over this domain's DNS records (can publish an
# arbitrary TXT record on request). There's no self-signed fallback in this project — every
# server ends up with a real, publicly-trusted cert one way or the other.
#
# DNS-01 is the only ACME challenge type that can issue a WILDCARD cert, which is exactly what
# we want here: one manual TXT-record challenge covers *.{BASE_DOMAIN} — all six subdomains
# (chat/agent/dashboard/memory/memapi/ragui) — instead of needing six separate ones. See
# LAB_GUIDE.md Appendix 1.3 for the full picture of both TLS options this project supports.
#
# Run as the same normal sudo-capable user install.sh was run as, not root. Safe to re-run: if
# a non-expiring-soon cert already exists, it just re-wires Caddy to it without bothering
# Let's Encrypt or you again.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
fi

# This script calls plain `docker compose` (no sudo) below. If install.sh's `usermod -aG docker`
# ran in a different session than this one (e.g. this is the first script run after install.sh
# finished, without logging out and back in first), this shell won't have the docker group active
# yet even though the user is listed in it — same gap install.sh works around for itself.
if ! docker info >/dev/null 2>&1; then
  if [ "${AIAO_REEXEC_DOCKER_GROUP:-0}" = "1" ]; then
    echo "ERROR: still can't talk to Docker after relaunching via 'sg docker'." >&2
    echo "Log out and SSH back in (a fresh session, not just a new tab), then re-run this script." >&2
    exit 1
  fi
  if ! command -v sg >/dev/null 2>&1; then
    echo "ERROR: can't talk to Docker (permission denied), and 'sg' isn't available to work around it." >&2
    echo "Log out and SSH back in, then re-run this script." >&2
    exit 1
  fi
  echo "==> docker group membership isn't active in this shell yet — relaunching via 'sg docker' (no logout needed)"
  export AIAO_REEXEC_DOCKER_GROUP=1
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"
EDGE_ENV="$ROOT/edge-proxy/.env"

existing() { [ -f "$2" ] && grep -E "^${1}=" "$2" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

BASE_DOMAIN="$(existing BASE_DOMAIN "$EDGE_ENV")"
ACME_EMAIL="$(existing ACME_EMAIL "$EDGE_ENV")"
[ -n "$BASE_DOMAIN" ] && [ -n "$ACME_EMAIL" ] || {
  echo "ERROR: BASE_DOMAIN/ACME_EMAIL not found in edge-proxy/.env — run ./install.sh first." >&2
  exit 1
}

LIVE_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"
CERT_FILE="${LIVE_DIR}/fullchain.pem"
KEY_FILE="${LIVE_DIR}/privkey.pem"

echo "== Manual DNS-01 wildcard cert for *.${BASE_DOMAIN} =="
echo

if ! command -v certbot >/dev/null 2>&1; then
  echo "==> Installing certbot"
  sudo apt-get update -qq
  sudo apt-get install -y certbot
fi

# 14-day buffer: re-run comfortably ahead of the ~90-day Let's Encrypt lifetime without cutting
# it so close that a delayed re-run (DNS propagation, you being away) risks expiry.
NEED_NEW_CERT=1
if sudo test -f "$CERT_FILE" && sudo openssl x509 -checkend "$((14 * 86400))" -noout -in "$CERT_FILE" 2>/dev/null; then
  NEED_NEW_CERT=0
  expiry="$(sudo openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2-)"
  echo "==> Existing cert for *.${BASE_DOMAIN} is still valid until ${expiry} — reusing it."
  echo "    (delete /etc/letsencrypt/live/${BASE_DOMAIN}/ first, or wait until it's within 14"
  echo "    days of expiry, to force a fresh challenge instead)"
fi

if [ "$NEED_NEW_CERT" -eq 1 ]; then
  echo
  echo "==> Starting the manual DNS-01 challenge for *.${BASE_DOMAIN}"
  echo "    certbot will print a TXT record for you to create at your DNS provider, then pause"
  echo "    for you to confirm it before validating. Let it propagate before pressing Enter —"
  echo "    a too-early confirm is the most common way this fails."
  echo
  sudo certbot certonly --manual --preferred-challenges dns --agree-tos \
    -m "$ACME_EMAIL" -d "*.${BASE_DOMAIN}" --no-eff-email
fi

sudo test -f "$CERT_FILE" && sudo test -f "$KEY_FILE" || {
  echo "ERROR: certbot didn't produce the expected files at ${LIVE_DIR}/ — check its output above." >&2
  exit 1
}

echo
echo "==> Wiring edge-proxy (Caddy) to use this certificate"
# Docker creates a missing bind-mount source as a directory, not a file — if edge-proxy ever
# started before this file existed, fix that before writing real content into it. No sudo
# needed: removing an empty directory only needs write+execute on its parent, not root.
if [ -d "$ROOT/edge-proxy/tls-override.conf" ]; then
  rmdir "$ROOT/edge-proxy/tls-override.conf"
fi
printf 'tls %s %s\n' "$CERT_FILE" "$KEY_FILE" > "$ROOT/edge-proxy/tls-override.conf"
sudo mkdir -p /etc/letsencrypt
( cd "$ROOT/edge-proxy" && docker compose up -d --force-recreate caddy )

expiry="$(sudo openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2-)"
echo
echo "== Done =="
echo "Real trusted certificate in use for all *.${BASE_DOMAIN} hostnames, valid until: ${expiry}"
echo "Let's Encrypt certs last ~90 days and this manual DNS-01 flow has no auto-renewal hook —"
echo "re-run this script before then (or any time after that date, if you miss it)."
echo
if [ -f "$ROOT/my-ai-agent/client-chat-ui/docker-compose.local-certs.yml" ]; then
  echo "This server has a leftover docker-compose.local-certs.yml from a previous self-signed"
  echo "setup — no longer needed now that a real public CA is trusted everywhere. Clean it up:"
  echo "  rm my-ai-agent/client-chat-ui/docker-compose.local-certs.yml"
  echo "  (cd my-ai-agent/client-chat-ui && docker compose up -d)"
fi
