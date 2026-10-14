# Deploying with GitHub Actions

This repo follows the same self-hosted-runner pattern `my-mcp-tools` originally used on its
own (back when it was deployed as a separate repo), extended to cover all four stacks:
`client-chat-ui`, `agent-backend`, `mcp-hub`, and `edge-proxy`.

```
 Mac                     GitHub                                        Ubuntu test server
 ─────                   ──────                                        ──────────────────
 edit files              repo: agent-all-in-one (private)               self-hosted runner (your user)
 git push  ───────────►  Actions workflow  ◄──── polls for jobs ─────────  │
                         ├─ validate (GitHub cloud runner)                 ├─ checkout repo
                         └─ deploy   (runs on YOUR server) ──────────────► ├─ rsync → ~/agent-all-in-one
                                                                           └─ deploy.sh → docker compose x4
                                                                              (reads .env files + ~/mcp-secrets/
                                                                               already on the server)
```

### Two scripts, two purposes

- **`install.sh`** — one-time, interactive. Run it by hand, once per server: checks/installs
  prerequisites, then prompts for *everything* needed to run — domain/ACME email/dashboard+
  ragui credentials/AI Gateway IP **and** every business secret (Portkey, CyberArk Identity/
  Idira, mem0's AI Gateway key) — writes every `.env` file (and generates
  `~/mcp-secrets/{memory,postgres}.env`), sets up the firewall, then does the first
  `docker compose up`. Nothing needs hand-editing in a `.env` file first.
- **`deploy.sh`** — every time after that, non-interactive. Assumes `install.sh` already ran
  once (so the `.env` files and `~/mcp-secrets/` already exist) and just rebuilds/restarts
  all four stacks. This is what GitHub Actions runs on every push to `main`, and you can also
  run it by hand on the server.

Secrets are never in Git, matching the convention `mcp-hub` already uses: `.env` files are
`.gitignore`d everywhere in this repo, and `~/mcp-secrets/*.env` lives outside the deploy
folder entirely. `.github/workflows/deploy.yml`'s `rsync` step explicitly excludes `.env`,
`*.env`, and `.install-state`, so a deploy never overwrites or deletes the config `install.sh`
already wrote on the server.

---

## Part 1: Push the code to GitHub (on your Mac)

### 1.1 Git identity
```bash
git config --global user.name     # should print your name
git config --global user.email    # should print your GitHub email
```
Your email is already set; if `user.name` is empty:
```bash
git config --global user.name "Your Name"
```

### 1.2 Sign in to GitHub over HTTPS
If Git prompts for a password on the first push, paste a **personal access token**, not your
account password: GitHub → avatar → **Settings → Developer settings → Personal access tokens
→ Tokens (classic) → Generate new token** → tick **`repo`** and **`workflow`** scopes →
Generate → copy it. (`workflow` is required because this repo contains
`.github/workflows/deploy.yml`.) macOS saves it in the Keychain after the first successful
push, so you won't be asked again.

### 1.3 Turn this folder into a Git repo and commit
```bash
cd ~/Documents/ai-agent-all-in-one
git init -b main
git add .
git status
```
**Check the list carefully before committing.** It must **not** contain any `.env` file,
`.install-state`, or `my-mcp-tools/mcp-hub/proxy/certs/`. It **should** contain
`.github/workflows/deploy.yml`, `install.sh`, `deploy.sh`, and every `.env.example`.

```bash
git commit -m "Initial all-in-a-box setup: 4 stacks, installer, CI deploy"
```

### 1.4 Connect to GitHub and push
```bash
git remote add origin https://github.com/matthew20103/agent-all-in-one.git
git push -u origin main
```

### 1.5 Check the first workflow run
Repo → **Actions** tab → "Deploy agent-all-in-one":
- **validate** should turn green in a minute or two.
- **deploy** will say *"Waiting for a runner to pick up this job…"* — expected, the runner
  isn't installed yet. It starts automatically once Part 3 is done.

---

## Part 2: Prepare the Ubuntu server

You already provisioned it (4 vCPU / 8 GB / 300 GB). SSH in with your normal sudo user.

```bash
sudo apt-get update
sudo apt-get install -y git rsync
```
`install.sh` installs Docker, curl, openssl, and ufw itself — you don't need to do that
manually. Just make sure `rsync` and `git` are present (the runner needs
`rsync` for the deploy step; `git` for the checkout step).

### Copy the code once, manually, to run `install.sh`
The deploy folder is `~/agent-all-in-one` — a plain subfolder of the runner user's home
directory, not `/opt`. No `sudo`/`chown` setup needed: you already own your own home
directory, and the self-hosted runner (Part 3) runs as that same user.

The very first `install.sh` run needs to happen before any CI deploy makes sense (there's
nothing for `deploy.sh` to redeploy until `.env` files exist). Easiest: `rsync` this folder
over by hand once, run `install.sh`, then let GitHub Actions take over from here on.
```bash
# From your Mac:
rsync -a --exclude '.git/' ~/Documents/ai-agent-all-in-one/ <user>@<ubuntu-ip>:~/agent-all-in-one/

# On the Ubuntu server:
cd ~/agent-all-in-one
./install.sh
```
Have your business secrets ready before you start: Portkey gateway URL/API key/MCP gateway
URL/server slugs, CyberArk Identity (Idira) issuer/audience/JWKS URI/chat client ID+secret,
and an AI Gateway API key for mem0 (it'll offer to reuse the Portkey key if left blank).
`install.sh` prompts for all of it directly — see `ARCHITECTURE.md` §9 for the full checklist.

Once this completes successfully, `~/agent-all-in-one` has every `.env` file `deploy.sh`
needs, and every future deploy can go through GitHub Actions instead. The workflow's `deploy`
job resolves this same path itself (`$HOME/agent-all-in-one`, evaluated on the runner at run
time), so it always lands on the folder you just set up — no path to keep in sync by hand.

---

## Part 3: Install the self-hosted runner

### 3.1 Register it
GitHub repo → **Settings → Actions → Runners → New self-hosted runner** → Linux, x64 (or
ARM64 if applicable). Keep that page open for the download/config commands and token.

### 3.2 Download and configure (as your normal user, not root)
```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
# paste the page's "Download" commands (curl -o ... && tar xzf ...)

./config.sh --url https://github.com/matthew20103/agent-all-in-one \
            --token <TOKEN-FROM-GITHUB-PAGE> \
            --name ubuntu-agent-all-in-one \
            --labels agent-all-in-one \
            --unattended
```
The label **must** be `agent-all-in-one` — it matches `runs-on: [self-hosted,
agent-all-in-one]` in `.github/workflows/deploy.yml`. The token is single-use and expires in
about an hour; reload the GitHub page for a new one if it fails.

### 3.3 Run it as a service
```bash
cd ~/actions-runner
sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status        # should say "active (running)"
```
Confirm in GitHub: **Settings → Actions → Runners** shows `ubuntu-agent-all-in-one` as
**Idle** (green).

---

## Part 4: Let CI take over

From now on, a plain push deploys:
```bash
cd ~/Documents/ai-agent-all-in-one
# ...edit something...
git add -A
git status                 # must NOT list any .env file
git commit -m "..."
git push
```
Watch **Actions**: validate ✅ → deploy ✅. `deploy.sh`'s output (including `mcp-hub`'s own
bearer-token smoke tests) shows up in the **Deploy and smoke test** step log.

**Re-deploy without a code change**: Actions → "Deploy agent-all-in-one" → **Run workflow**,
or on the server: `~/agent-all-in-one/deploy.sh` (no `sudo`). Use this after editing a
`.env` file or anything in `~/mcp-secrets/` directly on the server.

**Changed the domain or a dashboard/ragui password?** Re-run `./install.sh` on the server by
hand (it's interactive and safe to re-run — see its own defaults-from-existing-values
behavior), then push or re-run the workflow to pick up any code changes too.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `git push`: asks for a password, then fails | Paste a personal access token (Part 1.2), not your GitHub password. |
| `git push`: `refusing to allow ... without 'workflow' scope` | Your token lacks the `workflow` scope — generate a new one with `repo` + `workflow`, remove the old one from macOS Keychain Access, push again. |
| deploy job stuck "Waiting for a runner" | `cd ~/actions-runner && sudo ./svc.sh status` on the server. Label must be exactly `agent-all-in-one`. |
| `deploy.sh: ERROR: cannot talk to Docker. Is ... mwan in the 'docker' group` in the Actions log | The runner **service** was started before (or around the same time as) `mwan` was added to the `docker` group — a systemd service caches group membership at start time, same issue `install.sh` auto-recovers from for interactive shells, but a running service needs an explicit restart instead: `cd ~/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh start`. Confirm with `id -nG mwan` (lists `docker`) and `systemctl show -p User 'actions.runner.*'` (prints `User=mwan`), then re-run the workflow. |
| `rsync: command not found` (deploy job) | `sudo apt-get install -y rsync` on the server, then re-run the job. |
| `rsync: ... Permission denied` | `~/agent-all-in-one` isn't owned by the runner's user (unlikely under your own home directory, but check `ls -ld ~/agent-all-in-one`) — `sudo chown -R "$USER":"$USER" ~/agent-all-in-one`. |
| `rsync: [Receiver] mkdir "..." failed: Permission denied` | The deploy job is targeting a path the runner user can't create. Confirm the workflow's "Set deploy dir" step resolves to `$HOME/agent-all-in-one` for the **runner's** user (`systemctl show -p User 'actions.runner.*'` on the server), not `/opt` or another user's home. |
| deploy.sh: `ERROR: ... is missing. Run ./install.sh ...` | The first manual `install.sh` run (Part 2) hasn't happened yet, or its `.env` files were deleted. Re-run `install.sh` on the server. |
| `docker compose config` fails in **validate** | A compose file has a real YAML/syntax error — the job log shows the exact line. Dummy secrets are pre-created by the workflow, so this isn't a missing-secret issue. |
| mcp-hub smoke test fails inside **deploy.sh** | Same troubleshooting as `my-mcp-tools/mcp-hub-guide.md` — it still applies, since `deploy.sh` just calls `my-mcp-tools/mcp-hub/scripts/deploy.sh` for that part. |

---

## Checklist

- [ ] Mac: git identity set, GitHub HTTPS sign-in works (PAT with `repo` + `workflow`)
- [ ] Mac: `git init`, commit (no `.env`/`.install-state` in `git status`), pushed to `matthew20103/agent-all-in-one`
- [ ] Actions: validate ✅, deploy waiting for runner
- [ ] Ubuntu: code rsynced once manually to `~/agent-all-in-one`; `./install.sh` run and completed successfully
- [ ] Ubuntu: runner installed with label `agent-all-in-one`, running as a service, shows **Idle** in GitHub
- [ ] Push (or **Run workflow**) → deploy job ✅, all four stacks' smoke output looks right
- [ ] DNS A records for all 6 hostnames point at this server (`ARCHITECTURE.md` §4)
