#!/usr/bin/env bash
# Pull the latest hub config, create any missing tokens, (re)start everything, and smoke-test each MCP route.
set -euo pipefail
cd "$(dirname "$0")/.."

PROXY_URL="http://127.0.0.1:8080"
SECRETS_DIR="$HOME/mcp-secrets"
TOKENS="$SECRETS_DIR/hub.env"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot talk to Docker. Is it installed and is $(id -un) in the 'docker' group (log out/in after adding)?" >&2
  exit 1
fi

if [ -d .git ]; then
  echo "==> git pull"
  git pull --ff-only
fi

echo "==> checking tokens in $TOKENS"
mkdir -p "$SECRETS_DIR"
if [ ! -O "$SECRETS_DIR" ] || { [ -e "$TOKENS" ] && [ ! -O "$TOKENS" ]; }; then
  echo "ERROR: $SECRETS_DIR (or hub.env) is not owned by $(id -un). Fix with:" >&2
  echo "  sudo chown -R $(id -un):$(id -un) $SECRETS_DIR" >&2
  exit 1
fi
chmod 700 "$SECRETS_DIR"
touch "$TOKENS"
chmod 600 "$TOKENS"
new_tokens=""
for var in $(grep -rhoE 'MCP_TOKEN_[A-Z0-9_]+' proxy/templates | sort -u); do
  if ! grep -qE "^${var}=.+" "$TOKENS"; then
    grep -vE "^${var}=" "$TOKENS" > "$TOKENS.tmp" || true
    echo "${var}=$(openssl rand -hex 32)" >> "$TOKENS.tmp"
    mv "$TOKENS.tmp" "$TOKENS"
    chmod 600 "$TOKENS"
    new_tokens="$new_tokens $var"
  fi
done

missing=0
for f in $(grep -hE '^[^#]*\$\{HOME\}/mcp-secrets/' servers/[!_]*/compose.yaml 2>/dev/null \
           | grep -oE 'mcp-secrets/[A-Za-z0-9_.-]+\.env' | sort -u); do
  path="$SECRETS_DIR/${f##*/}"
  if [ ! -f "$path" ]; then
    echo "ERROR: missing secrets file $path (create it, chmod 600, then re-run)" >&2
    missing=1
  fi
done
[ "$missing" = 0 ] || exit 1

echo "==> starting containers"
docker compose up -d --build --remove-orphans
docker compose up -d --force-recreate proxy

echo "==> smoke tests"
for i in $(seq 1 20); do
  curl -fsS "$PROXY_URL/healthz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$PROXY_URL/healthz" >/dev/null && echo "proxy            ok" || echo "proxy            FAILED"

failed=0
for route in proxy/templates/routes/*.conf.template; do
  [ -e "$route" ] || continue
  name=$(basename "$route" .conf.template)
  var=$(grep -hoE 'MCP_TOKEN_[A-Z0-9_]+' "$route" | head -n1)
  token=$(grep -E "^${var}=" "$TOKENS" | cut -d= -f2-)

  noauth=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY_URL/$name/mcp")

  authed="000"
  for i in $(seq 1 15); do
    authed=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY_URL/$name/mcp" \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    [ "$authed" = "200" ] && break
    sleep 2
  done

  if [ "$noauth" = "401" ] && [ "$authed" = "200" ]; then
    printf '%-16s ok   (no token -> 401, token -> tools/list 200)\n' "$name"
  else
    printf '%-16s FAIL (no token -> %s, token -> %s)  check: docker compose logs\n' "$name" "$noauth" "$authed"
    failed=1
  fi
done

docker compose ps

if [ -n "$new_tokens" ]; then
  echo
  if [ "${CI:-}" = "true" ]; then
    # Never print token values into CI logs.
    echo "==> NEW tokens were generated:$new_tokens"
    echo "    Read them on the server: grep MCP_TOKEN_ $TOKENS"
  else
    echo "==> NEW tokens were generated (stored in $TOKENS). Add each to the AI Gateway as 'Authorization: Bearer <token>':"
    for var in $new_tokens; do
      grep -E "^${var}=" "$TOKENS"
    done
  fi
fi

exit $failed
