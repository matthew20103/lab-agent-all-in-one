#!/usr/bin/env bash
# Makes client-chat-ui's server-side Node process trust Caddy's internal CA — needed only
# when running with CADDY_LOCAL_CERTS=local_certs (a private-network deployment with no real
# public cert; see LAB_GUIDE.md section 1.3). Without this, NextAuth's Basic-Auth login flow
# (which calls the agent backend over HTTPS *from inside* the chat_ui container) fails with
# "fetch failed" / "UNABLE_TO_GET_ISSUER_CERT_LOCALLY" — which NextAuth then misreports to the
# user as a wrong-username/password error, nothing to do with the actual credentials. A
# browser can be told to trust a self-signed-style cert by clicking through a warning; Node's
# own fetch() has no such mechanism and just rejects it.
#
# Safe to re-run any time (e.g. after edge-proxy's data volume was recreated and generated a
# new internal CA) — it always re-extracts the current cert and recreates chat_ui to pick it
# up, which also serves as "restart the container if needed".
#
# Run as the same normal sudo-capable user install.sh was run as, not root.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo. Run it as your normal user; it calls sudo itself where needed." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"
CHAT_UI_DIR="$ROOT/my-ai-agent/client-chat-ui"
CERT_PATH="$HOME/caddy-local-root-ca.crt"
OVERRIDE_FILE="$CHAT_UI_DIR/docker-compose.local-certs.yml"

if ! docker ps --format '{{.Names}}' | grep -qx edge-proxy; then
  echo "ERROR: the edge-proxy container isn't running. Start the stack first (./install.sh or ./deploy.sh)." >&2
  exit 1
fi

echo "==> extracting Caddy's internal CA root cert"
docker exec edge-proxy cat /data/caddy/pki/authorities/local/root.crt > "$CERT_PATH"
if ! grep -q "BEGIN CERTIFICATE" "$CERT_PATH"; then
  echo "ERROR: that didn't look like a certificate. Is this server actually running in" >&2
  echo "       CADDY_LOCAL_CERTS=local_certs mode? If it already has a real public cert" >&2
  echo "       (Let's Encrypt), this script isn't needed at all — don't apply it." >&2
  rm -f "$CERT_PATH"
  exit 1
fi
echo "    saved to $CERT_PATH"

# Idempotent: (re)write the override file in case this script is run on a server that hasn't
# picked it up from a deploy yet, or its content ever changes.
echo "==> ensuring the local-certs override file is in place"
cat > "$OVERRIDE_FILE" <<'EOF'
# Opt-in override for private-network deployments running Caddy's internal CA
# (CADDY_LOCAL_CERTS=local_certs — see LAB_GUIDE.md Appendix 1.3). Applied by
# trust-caddy-local-ca.sh at the repo root; see that script for the full explanation.
# Not needed (and should not be applied) once the server has a real public IP and switches to
# genuine Let's Encrypt certs — at that point just go back to plain `docker compose up -d`.
services:
  chat_ui:
    environment:
      - NODE_EXTRA_CA_CERTS=/caddy-local-ca.crt
    volumes:
      - ${HOME}/caddy-local-root-ca.crt:/caddy-local-ca.crt:ro
EOF

echo "==> recreating chat_ui so it picks up the trusted cert"
( cd "$CHAT_UI_DIR" && docker compose -f docker-compose.yml -f docker-compose.local-certs.yml up -d --force-recreate chat_ui )

echo
echo "==> Done. Retry logging in now."
echo "    If it still fails, check the logs:"
echo "    (cd \"$CHAT_UI_DIR\" && docker compose logs -f chat_ui)"
