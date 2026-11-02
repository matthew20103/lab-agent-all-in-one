#!/usr/bin/env bash
# Gets a real, publicly-trusted wildcard TLS cert for *.{BASE_DOMAIN} via a MANUAL Let's
# Encrypt DNS-01 challenge, and wires edge-proxy (Caddy) to use it instead of either of
# install.sh's two automatic options (public Let's Encrypt HTTP-01, or CADDY_LOCAL_CERTS
# self-signed). For servers with outbound-only connectivity — no inbound 80/443 reachable from
# the public internet at all, so HTTP-01 can never succeed regardless of DNS — but full control
# over this domain's DNS records (can publish an arbitrary TXT record on request).
#
# DNS-01 is the only ACME challenge type that can issue a WILDCARD cert, which is exactly what
# we want here: one manual TXT-record challenge covers *.{BASE_DOMAIN} — all six subdomains
# (chat/agent/dashboard/memory/memapi/ragui) — instead of needing six separate ones. See
# LAB_GUIDE.md Appendix 1.3 for the full picture of all three TLS options this project supports.
#
# Run as the same normal sudo-capable user install.sh was run as, not root. Safe to re-run: if
# a non-expiring-soon cert already exists, it just re-wires Caddy to it without bothering
# Let's Encrypt or you again.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
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
echo "If this server was previously using CADDY_LOCAL_CERTS=local_certs, the"
echo "trust-caddy-local-ca.sh workaround for client-chat-ui is no longer needed (a real public"
echo "CA is already trusted everywhere) — safe to leave in place, or remove"
echo "my-ai-agent/client-chat-ui/docker-compose.local-certs.yml and re-run a plain"
echo "'docker compose up -d' there if you'd rather clean it up."
