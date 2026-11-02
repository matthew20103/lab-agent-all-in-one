#!/usr/bin/env bash
# Non-interactive redeploy: brings every stack up to date using whatever .env files and
# ~/mcp-secrets/ are already on this server. This is what GitHub Actions runs on every push
# to main (.github/workflows/deploy.yml), and it's safe to run by hand too.
#
# This is NOT the first-time setup script. For a brand-new server (prerequisites, the
# domain prompt, firewall rules, dashboard/ragui credentials), run ./install.sh once first —
# that one's interactive and only needs to happen once per server.
#
# Run as the same normal sudo-capable user install.sh was run as (the self-hosted GitHub
# Actions runner should also run as this user), not root.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run this as root or with sudo." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

# Same stale-group-membership issue install.sh guards against, but here it's usually the
# self-hosted GitHub Actions runner **service** that was started before this user was added to
# the docker group — a systemd service caches group membership at start time, same as any other
# long-running process. `sg docker -c '<command>'` sidesteps it: it recomputes group membership
# fresh from /etc/group at invocation time, regardless of what the calling process (the runner
# service, in this case) was started with — so relaunch through it once if `docker info` fails.
if ! docker info >/dev/null 2>&1; then
  if [ "${AIAO_REEXEC_DOCKER_GROUP:-0}" = "1" ]; then
    echo "ERROR: still can't talk to Docker after relaunching via 'sg docker'." >&2
    echo "If this runs under the GitHub Actions self-hosted runner, the runner service itself" >&2
    echo "may need a restart to pick up a NEW docker group membership (not just a new job):" >&2
    echo "  cd ~/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh start" >&2
    exit 1
  fi
  if ! command -v sg >/dev/null 2>&1; then
    echo "ERROR: can't talk to Docker (permission denied), and 'sg' isn't available to work around it." >&2
    exit 1
  fi
  echo "docker group membership isn't active in this process yet — relaunching via 'sg docker'"
  export AIAO_REEXEC_DOCKER_GROUP=1
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

for f in edge-proxy/.env my-ai-agent/agent-backend/.env my-ai-agent/client-chat-ui/.env my-mcp-tools/mcp-hub/.env; do
  if [ ! -f "$ROOT/$f" ]; then
    echo "ERROR: $f is missing. Run ./install.sh once on this server before the first deploy." >&2
    exit 1
  fi
done

# edge-proxy/docker-compose.yml bind-mounts tls-override.conf as a FILE (see
# obtain-manual-tls-cert.sh). install.sh creates it on first setup, but a server kept up to
# date purely via this script (the normal CI path) never ran that — and Docker silently
# creates a missing bind-mount SOURCE as a directory instead of a file, which then makes Caddy
# fail to parse `import tls-override.conf` and crash-loop with no useful error. Self-heal it
# here too, the same way install.sh does, so a plain `git pull` + deploy never hits this.
#
# No sudo here, by design: this script runs non-interactively under CI (no TTY, no cached sudo
# credential — a bare `sudo` call fails outright with "a terminal is required"). Neither
# operation actually needs root: removing an empty directory only needs write+execute on its
# PARENT (edge-proxy/, owned by the deploy user, not the entry itself), and /etc/letsencrypt is
# guaranteed to already exist by the time this script runs at all — install.sh creates it with
# sudo (interactively, with a real password prompt) in the very same step that writes the
# edge-proxy/.env this script just checked for above.
if [ -d "$ROOT/edge-proxy/tls-override.conf" ]; then
  echo "==> fixing edge-proxy/tls-override.conf (Docker created it as a directory, not a file)"
  rmdir "$ROOT/edge-proxy/tls-override.conf"
fi
[ -f "$ROOT/edge-proxy/tls-override.conf" ] || : > "$ROOT/edge-proxy/tls-override.conf"

echo "==> mcp-hub"
( cd "$ROOT/my-mcp-tools/mcp-hub" && ./scripts/deploy.sh )

echo
echo "==> agent-backend"
( cd "$ROOT/my-ai-agent/agent-backend" && docker compose up -d --build --remove-orphans )

echo
echo "==> client-chat-ui"
( cd "$ROOT/my-ai-agent/client-chat-ui" && docker compose up -d --build --remove-orphans )

echo
echo "==> edge-proxy"
# --force-recreate matters here specifically: Docker bakes a bind mount's file-vs-directory
# type into the container's rootfs at CREATE time, not at every start. A server whose edge-proxy
# container was ever created while tls-override.conf was wrongly a directory (the bug above)
# keeps failing to start even after the file is fixed on disk, until the container itself is
# recreated — a plain `up -d` reuses the existing container if its config hash is unchanged and
# never re-evaluates the mount type. obtain-manual-tls-cert.sh already force-recreates for the
# same reason; mirror that here so a CI redeploy self-heals a server stuck in that state too.
( cd "$ROOT/edge-proxy" && docker compose up -d --build --force-recreate --remove-orphans )

echo
echo "==> status"
( cd "$ROOT/my-ai-agent/agent-backend" && docker compose ps )
( cd "$ROOT/my-ai-agent/client-chat-ui" && docker compose ps )
( cd "$ROOT/edge-proxy" && docker compose ps )
( cd "$ROOT/my-mcp-tools/mcp-hub" && docker compose ps )
