# Guide: MCP Hub on Ubuntu behind Prisma AIRS AI Gateway

> **Note (all-in-a-box consolidation):** this hub is now deployed as part of the unified
> `agent-all-in-one` repo, alongside the chat client and backend agent, via the root
> `install.sh`/`deploy.sh` and `DEPLOYMENT.md` — not as its own standalone server/repo.
> Section 4 ("Prepare the Ubuntu server") and the RAGFlow instructions in Section 13 are
> superseded (`install.sh` handles prerequisites; RAGFlow was replaced by Chroma — see
> `servers/chroma/` and `ARCHITECTURE.md`). Everything else below (adding/operating MCP
> servers, memory, postgres, troubleshooting) still applies as-is.

Goal: one Ubuntu server hosting **many MCP servers**, starting with OpenSERP Google search. Each server is reachable only through an authenticated reverse proxy. The Prisma AIRS AI Gateway (MCP Gateway) registers each one with its own **bearer token** and controls which AI agents can use which tools.

Ready-to-deploy files are in [mcp-hub/](mcp-hub/).

---

## 1. First, what will the AI Gateway show for OpenSERP?

The gateway shows a list of **MCP tools (actions)**, which it gets from the server's `tools/list` response. It does **not** show a list of search engines to enable or disable.

With the official `@openserp/mcp` server you'll see these 10 tools:

| Tool | What it does | Engine choice |
|---|---|---|
| `search` | Web search on **one** engine | `engine` parameter: `google`, `bing`, `yandex`, `baidu`, `duck`, `duckduckgo`, `ecosia` |
| `image_search` | Image search on one engine | same `engine` parameter |
| `mega_search` | Search several engines at once, merge results | `engines` array parameter |
| `fast_search` | Fastest healthy engine | `engines` array parameter |
| `any_search` | Try engines in order until one answers | `engines` array parameter |
| `mega_image` | Image search on several engines | `engines` array parameter |
| `extract` | Fetch a URL as clean markdown | – |
| `batch_extract` | Fetch up to 20 URLs | – |
| `list_engines` | List available engines | – |
| `get_usage` | OpenSERP **Cloud** credits (fails on self-hosted) | – |

So "Google" is a **value the agent passes** (`engine: "google"`), not a separate action. To enforce Google-only you have two options:

- **Option 1: gateway policy (no code).** Allow only `search` (+ optionally `extract`/`batch_extract`), tell agents to use `engine: "google"`, and if the gateway supports argument guardrails, block `engine != "google"`. See section 7.
- **Option 2: a small custom wrapper MCP server.** It exposes clean actions like `google_search` and `web_extract` and forces the engine on the server side. The gateway then shows exactly the actions you want, and nothing can pick another engine. This slots into the hub as a new server (section 9, option C). Ask Claude to build it if you want this.

---

## 2. Architecture

```
AI Agent ──(agent's gateway credential)──► Prisma AIRS AI Gateway / MCP Gateway
                                            │  per-agent access control, guardrails, logs
                                            │
                          Authorization: Bearer <per-server token>
                                            ▼
Ubuntu server <UBUNTU_IP>  (firewall: port 8080/8443 open to gateway only)
┌─────────────────────────────────────────────────────────────────────┐
│ mcp-proxy (nginx) :8080                                               │
│   /healthz            → 200 (no auth)                                 │
│   /openserp/mcp       → check token MCP_TOKEN_OPENSERP → openserp-mcp │
│   /<next>/mcp         → check token MCP_TOKEN_<NEXT>   → <next>-mcp   │
│   anything else       → 404                                           │
│                                                                       │
│  Docker network (internal, no published ports)                        │
│   openserp-mcp :3333 ──► openserp :7000 ──► headless Chrome ──► Google │
│   <next>-mcp   :8000                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

There are two separate authentication layers:
1. **Agent → Gateway**: the agent's existing gateway identity (API key, workspace or user group). This decides **which agent** can use which MCP server and tools.
2. **Gateway → Hub**: a **bearer token per MCP server**, checked by nginx. Only the gateway knows these tokens, so agents can't skip the gateway.

The firewall (only the gateway IP can reach the hub) adds a third layer.

---

## 3. Folder layout and conventions

```
mcp-hub/
├── compose.yaml                         # proxy + include: list of servers
├── .gitignore
├── .github/workflows/deploy.yml         # validate on GitHub, deploy on the self-hosted runner
├── scripts/deploy.sh                    # tokens + compose up + smoke tests
├── proxy/
│   ├── templates/
│   │   ├── default.conf.template        # nginx server block, includes routes/
│   │   └── routes/
│   │       └── openserp.conf.template   # one route file per MCP server
│   └── snippets/mcp-proxy.conf          # shared streaming/timeout settings
└── servers/
    ├── openserp/
    │   ├── compose.yaml                 # openserp + openserp-mcp
    │   ├── Dockerfile.mcp               # builds @openserp/mcp (pinned 0.1.7)
    │   └── config.yaml                  # OpenSERP config tuned for Google
    └── _template/                       # copy this to add a new server
        ├── compose.yaml
        └── route.conf.template.example

~/mcp-secrets/                           # on the Ubuntu server only, outside the repo (chmod 700)
├── hub.env                              # MCP_TOKEN_<NAME>=...   (deploy.sh creates missing tokens)
└── <name>.env                           # API keys a specific MCP server needs (optional)
```

Every MCP server follows the same conventions:

| Item | Convention (example for `openserp`) |
|---|---|
| Folder | `servers/<name>/` |
| Backend container | unique `container_name`, serves Streamable HTTP at `/mcp`, **no published ports** |
| Public URL | `http://<UBUNTU_IP>:8080/<name>/mcp` |
| Token variable | `MCP_TOKEN_<NAME>` in `~/mcp-secrets/hub.env` |
| Route file | `proxy/templates/routes/<name>.conf.template` |
| Backend's own secrets | `~/mcp-secrets/<name>.env`, referenced as `env_file: ${HOME}/mcp-secrets/<name>.env` (kept separate from the hub tokens) |

Run `docker compose` as your own user, **not with `sudo`**. The compose files use `${HOME}` to find `~/mcp-secrets/`.

How the token check works: at start-up, the nginx image renders `*.template` files and fills in `${MCP_TOKEN_*}` from `~/mcp-secrets/hub.env`. Each route then rejects any request whose `Authorization` header isn't exactly `Bearer <token>` with **401**. The proxy strips the header before forwarding, so backends never see the hub token.

---

## 4. Prepare the Ubuntu server

Requirements: Ubuntu 22.04/24.04, **≥ 2 vCPU / 4 GB RAM** (more as you add servers), outbound internet access, and the AI Gateway able to reach `<UBUNTU_IP>:8080`.

Install Docker Engine + Compose plugin (Compose **v2.20+** is required for `include:`):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl openssl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER      # log out and back in afterwards
docker compose version             # must be v2.20 or newer
```

---

## 5. Deploy the hub with OpenSERP

> **Recommended:** auto-deploy with GitHub Actions. See [github-actions-deploy-guide.md](github-actions-deploy-guide.md). The manual steps below still work if you'd rather not use GitHub.

### 5.1 Copy the folder to Ubuntu (from your Mac)

```bash
scp -r ~/Documents/my-mcp-tools/mcp-hub <user>@<UBUNTU_IP>:~/
```

### 5.2 Create the token file in `~/mcp-secrets/` (on Ubuntu)

```bash
mkdir -p ~/mcp-secrets && chmod 700 ~/mcp-secrets
echo "MCP_TOKEN_OPENSERP=$(openssl rand -hex 32)" > ~/mcp-secrets/hub.env
chmod 600 ~/mcp-secrets/hub.env
cat ~/mcp-secrets/hub.env     # store this token safely; you'll paste it into the AI Gateway
```
(`scripts/deploy.sh` does this automatically if the file or a token is missing.)

### 5.3 Review OpenSERP settings (optional)

[servers/openserp/config.yaml](mcp-hub/servers/openserp/config.yaml) is already tuned. Key values:
- `google.rate_requests: 10`: requests per minute to Google (keep it low to avoid CAPTCHAs)
- `cache.ttl_seconds: 600`: repeated queries are served from cache
- `resilience.allow_endpoint_fallback: false`: a Google search never silently falls back to another engine
- `proxies.allow_request_proxy_url: false`: callers can't make OpenSERP send traffic through arbitrary proxies

### 5.4 Start

```bash
docker compose up -d --build
docker compose ps                    # mcp-proxy, openserp, openserp-mcp all Up (openserp-mcp healthy)
docker compose logs -f --tail=50     # Ctrl+C to exit
```

### 5.5 Test from the Ubuntu server

```bash
cd ~/mcp-hub
TOKEN=$(grep '^MCP_TOKEN_OPENSERP=' ~/mcp-secrets/hub.env | cut -d= -f2)

# a) OpenSERP REST API talks to Google
curl -s "http://127.0.0.1:7000/google/search?text=palo+alto+networks&limit=3" | head -c 800; echo

# b) Proxy is up
curl -s http://127.0.0.1:8080/healthz                     # ok

# c) No token → 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/openserp/mcp

# d) Wrong token → 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/openserp/mcp -H 'Authorization: Bearer wrong'

# e) Valid token → list of MCP tools
curl -s http://127.0.0.1:8080/openserp/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# f) Google search via MCP
curl -s http://127.0.0.1:8080/openserp/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"engine":"google","text":"prisma airs","limit":5}}}'
```

✅ **Checkpoint:** (a) returns Google JSON, (c)/(d) return `401`, (e) lists the 10 tools, (f) returns Google results in `result.content[0].text`.

Optional GUI test from your laptop, before the firewall is locked down:
```bash
npx @modelcontextprotocol/inspector
# Transport: Streamable HTTP
# URL: http://<UBUNTU_IP>:8080/openserp/mcp
# Header: Authorization = Bearer <token>
```

---

## 6. Firewall: allow only the AI Gateway

Docker-published ports **bypass UFW**, so restrict the proxy port in the `DOCKER-USER` chain.

### 6.1 Find the gateway's source IP
Your notes list both `192.168.110.25` and `192.168.110.161`. On Ubuntu, run:
```bash
sudo tcpdump -ni any tcp port 8080
```
Then, from the gateway host, run `curl http://<UBUNTU_IP>:8080/healthz`. The source IP shown is `<GATEWAY_SRC_IP>`.

### 6.2 Apply

```bash
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 8080 ! -s <GATEWAY_SRC_IP> -j DROP
# if TLS is enabled (section 8), do the same for 8443
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save

sudo ufw allow OpenSSH
sudo ufw enable
```

✅ **Checkpoint:** `curl http://<UBUNTU_IP>:8080/healthz` works from the gateway host and times out from anywhere else.

This single rule covers **every** future MCP server, because they all sit behind the same proxy port.

---

## 7. Register in Prisma AIRS AI Gateway and control agent access

Use your GitHub MCP setup as the template. Menu names depend on your gateway version.

### 7.1 Add the MCP server

| Field | Value |
|---|---|
| Name / slug | `openserp-search` |
| Transport | **Streamable HTTP** |
| URL | `http://<UBUNTU_IP>:8080/openserp/mcp` (or `https://<UBUNTU_IP>:8443/openserp/mcp` with TLS) |
| Authentication | Bearer token / custom header: `Authorization: Bearer <MCP_TOKEN_OPENSERP>` |
| Timeout | ≥ 60 s (Google searches through headless Chrome take 5–20 s) |

Save, then run **test / discover tools**. You should see the 10 tools from section 1.

> Use Streamable HTTP, not SSE. The legacy SSE transport tells the client to post to `/messages` without the `/openserp` prefix, so it breaks behind path-based routing.

### 7.2 Restrict the tools (least privilege)
Enable only what agents need:
- ✅ `search` (with agent instruction: *"For web search, call `search` with `engine: "google"`."*)
- ✅ optional: `extract`, `batch_extract`
- ❌ `mega_search`, `fast_search`, `any_search`, `image_search`, `mega_image`, `list_engines`, `get_usage`

If the gateway supports argument-level guardrails, reject `search` calls where `engine` is not `google`. Or use the custom wrapper from section 1, option 2.

> If Google returns `captcha detected` (Google blocks the headless browser), tell agents to use `engine: "bing"` or `engine: "duckduckgo"` until a captcha solver is set up. Both work with no extra configuration.

### 7.3 Grant access per agent
1. Give each agent its own gateway identity (e.g. `agent-research`, `agent-support`).
2. Grant `openserp-search` only to agents that should search the web.
3. Turn on AIRS scanning of MCP tool **responses**. Web pages and search snippets are untrusted content and a common prompt-injection path.
4. Turn on request logging for auditing.

### 7.4 Test

| Test | Expected |
|---|---|
| Allowed agent lists tools | sees `search` (+ `extract` if allowed) |
| Allowed agent: "search Google for …" | real Google results |
| Denied agent lists tools / calls `search` | not visible, or 401/403 from the gateway |
| Anyone calls `<UBUNTU_IP>:8080` directly | blocked by firewall; 401 even if the firewall is bypassed |

---

## 8. Optional: enable TLS (recommended)

Over plain HTTP, the bearer token can be read by anyone who can sniff the network between the gateway and Ubuntu. To add TLS:

```bash
cd ~/mcp-hub
mkdir -p proxy/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout proxy/certs/mcp-hub.key -out proxy/certs/mcp-hub.crt \
  -subj "/CN=mcp-hub" -addext "subjectAltName=IP:<UBUNTU_IP>"
chmod 600 proxy/certs/mcp-hub.key
```

1. In [compose.yaml](mcp-hub/compose.yaml), uncomment the `certs` volume and `8443:8443` port.
2. In [default.conf.template](mcp-hub/proxy/templates/default.conf.template), uncomment the `listen 8443 ssl` and `ssl_certificate*` lines.
3. `docker compose up -d` and test with `curl -k https://127.0.0.1:8443/healthz`.
4. Have the gateway trust `mcp-hub.crt`, or use a certificate from your internal CA. Change the registered URL to `https://…:8443/…`.
5. Once the gateway works over TLS, remove `listen 8080` and the `8080:8080` port mapping, and move the firewall rule to 8443.

---

## 9. Adding a new MCP server (repeatable recipe)

Example: adding a server called `weather`.

**Step 1: create the folder**
```bash
cd ~/mcp-hub
cp -r servers/_template servers/weather
```

**Step 2: edit `servers/weather/compose.yaml`.** Keep one option, rename the service and `container_name` to `weather-mcp`, and set the port:

| Your MCP server is… | Use |
|---|---|
| Already Streamable HTTP (has a Docker image or an `--http` flag) | **Option A**: run its image directly |
| stdio-only (most `npx …` / `uvx …` MCP servers) | **Option B**: wrap with `supercorp/supergateway` using `--outputTransport streamableHttp`, which serves `/mcp` |
| Your own code (e.g. the Google-only wrapper) | **Option C**: `build: .` with a Dockerfile in the folder |

Put any API keys that server needs in `~/mcp-secrets/weather.env` **on the Ubuntu server** (`chmod 600`), referenced in its compose file with `env_file: ${HOME}/mcp-secrets/weather.env`.

**Step 3: add it to the root [compose.yaml](mcp-hub/compose.yaml)**
```yaml
include:
  - servers/openserp/compose.yaml
  - servers/weather/compose.yaml
```

**Step 4: add the route**
```bash
cp servers/weather/route.conf.template.example proxy/templates/routes/weather.conf.template
sed -i 's/example/weather/g; s/EXAMPLE/WEATHER/g' proxy/templates/routes/weather.conf.template
# check the port in the file matches your backend (default 8000)
rm servers/weather/route.conf.template.example
```

**Step 5: add a token** (skip if you deploy with `scripts/deploy.sh`, which generates missing tokens)
```bash
echo "MCP_TOKEN_WEATHER=$(openssl rand -hex 32)" >> ~/mcp-secrets/hub.env
```

**Step 6: start and reload the proxy**
```bash
docker compose up -d --build
docker compose up -d --force-recreate proxy   # picks up the new token and re-renders routes
```
(`restart` is enough when you only change a route template. A change to `~/mcp-secrets/hub.env` needs `--force-recreate`.)

**Step 7: test** (same as 5.5 e) with `/weather/mcp` and the new token, then register `http://<UBUNTU_IP>:8080/weather/mcp` in the AI Gateway with its own bearer token and grant it to the right agents.

To **remove** a server, delete its `include` line, its route template and its token, then run `docker compose up -d --remove-orphans && docker compose up -d --force-recreate proxy`.

---

## 10. Operations

**Rotate a token** (brief interruption for that one server):
```bash
cd ~/mcp-hub
NEW=$(openssl rand -hex 32)
sed -i "s/^MCP_TOKEN_OPENSERP=.*/MCP_TOKEN_OPENSERP=$NEW/" ~/mcp-secrets/hub.env
docker compose up -d --force-recreate proxy    # env_file changes need a recreate, not just restart
echo $NEW    # update the bearer token in the AI Gateway right away
```

**Upgrade**
```bash
docker compose pull                   # openserp, nginx, supergateway images
# to upgrade @openserp/mcp: bump the version in Dockerfile.mcp and the image tag in servers/openserp/compose.yaml
docker compose up -d --build
```
After upgrading an MCP server, re-run **discover tools** in the gateway. New tools may appear that you haven't reviewed yet.

**Logs**
```bash
docker compose logs -f proxy          # access log: who called which route, status codes
docker compose logs -f openserp openserp-mcp
```

---

## 11. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Proxy won't start: `unknown "mcp_token_xxx" variable` | A route template references a token missing from `~/mcp-secrets/hub.env`. Add it and run `docker compose up -d --force-recreate proxy`. |
| Always `401` with the right token | Header must be exactly `Authorization: Bearer <token>` (capital B, one space). Check `~/mcp-secrets/hub.env` has no quotes or trailing spaces. After editing it, recreate the proxy. |
| `env file /root/mcp-secrets/hub.env not found` | You ran `sudo docker compose`. Run it as your own user (in the `docker` group) without `sudo`. |
| `~/mcp-secrets/hub.env`: `Permission denied` | Created with `sudo`, so root owns it. Run `sudo chown -R $USER:$USER ~/mcp-secrets && chmod 700 ~/mcp-secrets && chmod 600 ~/mcp-secrets/*.env`. |
| `502 Bad Gateway` | Backend is down or the name/port in the route is wrong: `docker compose ps`, `docker compose logs <service>`. |
| `404` on `/<name>/mcp` | Route file missing, or not named `*.conf.template`; run `docker compose restart proxy`. |
| Google CAPTCHA / `blocked` / empty results | Google is flagging your IP. Lower `google.rate_requests`, raise the cache TTL, or use a residential proxy (`proxies.entries` + `google.proxy: <tag>`). Last resort: 2captcha (`2captcha.apikey`, `captcha.solver_enabled: true`, `google.captcha: true`). |
| Chrome "Out of memory" | Keep `shm_size: 2gb`; lower `app.max_processes`; add RAM. |
| Gateway times out on `search` | Raise the gateway MCP timeout to ≥ 60 s; check `docker compose logs openserp`. |
| Gateway can't connect at all | Wrong firewall source IP (redo 6.1) or a routing issue between subnets. |
| `unknown_session` errors | Gateway is using SSE. Switch it to Streamable HTTP (section 7.1). |

---

## 12. Checklist

- [ ] Docker + Compose ≥ v2.20 on Ubuntu
- [ ] `mcp-hub/` copied; `~/mcp-secrets/hub.env` created with `MCP_TOKEN_OPENSERP` (folder chmod 700, file chmod 600)
- [ ] `docker compose up -d --build`: all containers up
- [ ] Tests 5.5 a–f pass (Google results, 401 without token, tools listed)
- [ ] Firewall: port 8080 (and 8443) reachable only from the gateway
- [ ] Optional: TLS enabled, gateway trusts the cert
- [ ] `openserp-search` registered in AI Gateway with its bearer token, tools discovered
- [ ] Tool allowlist: `search` (+ optional `extract`) only
- [ ] Access granted only to chosen agents; denied agent tested
- [ ] Response scanning and logging enabled
- [ ] Next MCP server added using section 9

---

## 13. Knowledge base (RAGFlow)

**What it is:** RAGFlow v0.27.2 in `servers/ragflow/`.
- You upload documents in its web UI.
- Agents search them via the MCP tool `ragflow_retrieval`.
- Embeddings and reranking come from the AI Gateway.

**Containers** (`servers/ragflow/compose.yaml`):

| Container | Role |
|---|---|
| `ragflow-server` | API, web UI and document parsing |
| `ragflow-es` | Elasticsearch: keyword and vector index |
| `ragflow-mysql` | Metadata |
| `ragflow-minio` | Original files |
| `ragflow-redis` | Task queue |
| `ragflow-mcp` | MCP server |

**Ports:** only the web UI is published, on `:8081`. The MCP endpoint is `/ragflow/mcp` behind the hub proxy, like every other server.

**How retrieval works:**
1. Parsing (DeepDoc) splits each document into chunks of about 512 tokens.
2. Each chunk is embedded and stored in Elasticsearch with a BM25 keyword index and an HNSW vector index.
3. A question runs a hybrid search: 30% vector and 70% keyword by default (`vector_similarity_weight`).
4. The optional reranker re-scores the top hits.
5. The agent gets the best chunks with their document names, which it can cite.

### 13.1 One-time server prep (on `ubuntu-mcp-tools`, as `mwan`)
1. **Resources:** give the VM at least 8 vCPU, 32 GB RAM and 200 GB disk. The minimum is 4 vCPU / 16 GB.
2. **Elasticsearch kernel setting:**
   ```bash
   echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf && sudo sysctl --system
   ```
3. **Secrets file.** The command below creates it with random passwords and refuses to overwrite an existing one. The passwords are fixed into the data volumes on first start, so don't change them afterwards.
   ```bash
   [ -e ~/mcp-secrets/ragflow.env ] && echo "ragflow.env already exists" || ( umask 077; M=$(openssl rand -hex 16); S=$(openssl rand -hex 16); printf '%s\n' "ELASTIC_PASSWORD=$(openssl rand -hex 16)" "MYSQL_PASSWORD=$M" "MYSQL_ROOT_PASSWORD=$M" "MINIO_USER=ragflow" "MINIO_PASSWORD=$S" "MINIO_ROOT_USER=ragflow" "MINIO_ROOT_PASSWORD=$S" "REDIS_PASSWORD=$(openssl rand -hex 16)" "REGISTER_ENABLED=1" > ~/mcp-secrets/ragflow.env && echo created )
   ```
4. **AI Gateway:** create an API key for RAGFlow. The models come from the Vertex provider `google-vertex-sep`, and model names must use the form `@<provider-slug>/<model>`; without it the gateway asks for an `x-portkey-config` header.
   - Embedding model: `@google-vertex-sep/text-embedding-005` (768 dimensions).
   - Rerank model: `@google-vertex-sep/semantic-ranker-default-004` (the Vertex AI Ranking API).
   - The LLM API is on port **80**: `http://192.168.110.161/v1`. Port 8788 is only the MCP gateway.
   - Choose the embedding model carefully. Changing it later means re-parsing every document.
   - The reranker needs two things in GCP project `prod-q6n0rq`: the Discovery Engine API enabled, and the permission `discoveryengine.rankingConfigs.rank` for the gateway's Vertex service account `portkey-vertex-sa`. Grant it through the custom role `projects/prod-q6n0rq/roles/discoveryEngineRanker`, which holds only that permission. `roles/discoveryengine.user` does **not** include it. Without them you get `Permission 'discoveryengine.rankingConfigs.rank' denied`.

### 13.2 Phase 1: start RAGFlow and set it up
1. Push the repo. The deploy starts everything except `ragflow-mcp`, which has `profiles: ["mcp"]`.
2. The first start takes a few minutes. Check with `docker compose ps`; the ragflow containers should be `healthy` or `running`.
3. Open `http://192.168.110.25:8081` and **register your account**. The first account becomes the owner of the datasets.
4. Close registration so nobody else can sign up:
   ```bash
   sed -i 's/^REGISTER_ENABLED=.*/REGISTER_ENABLED=0/' ~/mcp-secrets/ragflow.env && cd /opt/mcp-hub && docker compose up -d --force-recreate ragflow-server
   ```
5. **Model providers:** add **OpenAI-API-Compatible** with:
   - base URL `http://192.168.110.161/v1` (port 80, not 8788)
   - the gateway API key
   - the embedding model `@google-vertex-sep/text-embedding-005` (type *embedding*)
   - the rerank model `@google-vertex-sep/semantic-ranker-default-004` (type *rerank*)

   Then set both as the defaults in *System model settings*.
6. **Create a dataset per topic** (for example `hr-policies`, `product-docs`):
   - Embedding model: the gateway one.
   - Chunk method: *General* for most documents, or *Manual*, *Paper*, *Laws*, *Q&A* or *Table* when they fit better.
   - Write a one-line **description**. The agent sees it in the tool description and uses it to pick datasets.
7. **Upload** files, select them and click **Parse**. Upload large sets in batches of a few hundred.
8. **Retrieval testing** (in the dataset): ask real questions. Tune the *similarity threshold*, the *vector weight* and the *rerank model* until the right chunks come first.
9. **API key:** click your avatar → *API* → create a key. Then add it to the secrets file:
   ```bash
   nano ~/mcp-secrets/ragflow.env      # add: RAGFLOW_MCP_HOST_API_KEY=ragflow-xxxxxxxx
   ```

### 13.3 Phase 2: enable the MCP endpoint
In the repo:
1. In `servers/ragflow/compose.yaml`, delete the `profiles: ["mcp"]` line.
2. Copy `servers/_template/route.conf.template.example` to `proxy/templates/routes/ragflow.conf.template`.
   - Replace `example` → `ragflow` and `EXAMPLE` → `RAGFLOW`.
   - Set the upstream to `http://ragflow-mcp:9382`.
3. Push.

The deploy log should show:
```
ragflow          ok   (no token -> 401, token -> tools/list 200)
NEW tokens were generated: MCP_TOKEN_RAGFLOW
```

Register it in the AI Gateway as in section 7:

| Field | Value |
|---|---|
| Slug | `knowledge-base` |
| Transport | Streamable HTTP |
| URL | `http://192.168.110.25:8080/ragflow/mcp` |
| Auth | `Authorization: Bearer <MCP_TOKEN_RAGFLOW>` |
| Timeout | 60 s |

Then allow only `ragflow_retrieval` (and optionally `ragflow_list_datasets`).

**Agent system prompt:** the reranker is used only when the agent passes `rerank_id`, so add a line like this:
> For company knowledge, call `ragflow_retrieval` with `question`, `page_size: 8` and `rerank_id: "<rerank model name as shown in RAGFlow>"`. Cite the document names you used.

**Test from another host** (one command; returns chunks with `document_name`):
```bash
curl -sS -m 60 http://192.168.110.25:8080/ragflow/mcp -H "Authorization: Bearer <TOKEN>" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ragflow_retrieval","arguments":{"question":"<a question about an uploaded document>","page_size":3}}}'
```

### 13.4 Operations
- **Firewall:** section 6 limits only port 8080. The UI on 8081 stays open on the LAN; it is protected by RAGFlow's own login. To limit it to one admin PC:
  ```bash
  sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 8081 ! -s <ADMIN_PC_IP> -j DROP
  ```
  `--ctorigdstport` matches the host port the client connected to (8081), before Docker translates it to container port 80. Then run `sudo netfilter-persistent save`.
- **Back up.** This stops the knowledge base for a few minutes so the copies are consistent:
  ```bash
  cd /opt/mcp-hub && S="ragflow-mcp ragflow-server ragflow-es ragflow-mysql ragflow-minio" && docker compose stop $S && mkdir -p ~/backups && for v in ragflow_mysql ragflow_minio ragflow_esdata; do docker run --rm -v mcp-hub_$v:/d:ro -v ~/backups:/b alpine tar czf /b/$v-$(date +%F).tgz -C /d .; done; docker compose up -d
  ```
- **Upgrade:**
  1. Read the RAGFlow release notes first.
  2. Bump the tag in both `ragflow-server` and `ragflow-mcp`.
  3. Back up before pushing.
- **Logs:** `docker compose logs -f ragflow-server ragflow-mcp`.
- **Troubleshooting:**

  | Symptom | Fix |
  |---|---|
  | `ragflow-es` keeps restarting | `vm.max_map_count` not set (13.1), or not enough RAM |
  | Parsing stuck or failing | `docker compose logs ragflow-server`. Check that the embedding model works in RAGFlow's model settings and the gateway isn't rate-limiting |
  | `ragflow` smoke test not 200 | `RAGFLOW_MCP_HOST_API_KEY` is missing or wrong in `ragflow.env`. Fix it, then `docker compose up -d --force-recreate ragflow-mcp` |
  | Agent: "MCP tool(s) unavailable"; gateway log: `401 Authorization Required` (nginx HTML) | The gateway is sending the wrong token. A common mistake is pasting the RAGFlow API key (`ragflow-…`, 51 chars) instead of `MCP_TOKEN_RAGFLOW` (64 hex chars). The RAGFlow key belongs only in `ragflow.env` |
  | `ragflow_retrieval` returns nothing | Documents not parsed yet, or the threshold is too high; try `similarity_threshold: 0.1` |

---

## 14. Agent memory (mem0)

Long-term memory **per end user**: preferences, facts and decisions that should survive between conversations. The user ID is the person's **email from the CyberArk IAM login**.

| Container | What it does | Port |
|---|---|---|
| `memory-mcp` | Our MCP wrapper (`servers/memory/mcp/server.py`), stateless, tools below | none (via proxy `/memory/mcp`) |
| `memory-api` | Official mem0 v2.2.1 REST server: fact extraction, update/merge, search | `8083` (LAN; needs a key) |
| `memory-dashboard` | mem0 dashboard: browse/delete memories per user, audit log, settings | `8082` (LAN; needs a login) |
| `memory-postgres` | Postgres 17 + pgvector: memories (`postgres` DB) and users/keys/audit (`mem0_app` DB) | none |

**How it works:**
1. `memory_add` sends text to mem0.
2. The LLM (Gemini Flash via the gateway) extracts short facts.
3. Each fact is embedded and compared with that user's existing facts.
4. The LLM decides **ADD / UPDATE / DELETE / NONE**, so contradictions replace old facts.
5. `memory_search` is a vector search **filtered to that user's email**.

| Tool | Arguments | Notes |
|---|---|---|
| `memory_search` | `user_id`, `query`, `limit` (1–20, default 5) | Returns facts with a score |
| `memory_add` | `user_id`, `content` | Returns the ADD/UPDATE/DELETE events |
| `memory_list` | `user_id`, `limit` (1–200, default 50) | "What do you remember about me?" |
| `memory_delete` | `user_id`, `memory_id` | Refused unless the memory belongs to that user |

`user_id` must be an email. The wrapper lowercases it, so `Alice@Company.com` and `alice@company.com` are the same person, and rejects anything else.

### 14.1 Before the first push (on `ubuntu-mcp-tools`, as `mwan`)
Create the secrets file. The command generates the passwords and keys, then asks for the **AI Gateway API key** (the input is hidden). It refuses to overwrite an existing file. Don't change `POSTGRES_PASSWORD` after the first start.
```bash
[ -e ~/mcp-secrets/memory.env ] && echo "memory.env already exists" || { read -rsp 'AI Gateway API key: ' K; echo; ( umask 077; printf '%s\n' "POSTGRES_USER=postgres" "POSTGRES_PASSWORD=$(openssl rand -hex 16)" "JWT_SECRET=$(openssl rand -hex 32)" "ADMIN_API_KEY=$(openssl rand -hex 32)" "OPENAI_API_KEY=$K" > ~/mcp-secrets/memory.env ) && echo created; unset K; }
```
Check: `ls -l ~/mcp-secrets/memory.env` shows `-rw-------`, and `cut -d= -f1 ~/mcp-secrets/memory.env` lists the 5 key names.

The chat model is set in `servers/memory/compose.yaml` (`MEM0_DEFAULT_LLM_MODEL`) and in the configure command in 14.2. Both use `@google-vertex-sep/gemini-3.6-flash`, the same chat model as in RAGFlow. To switch models later, re-run the configure command with the new name; that needs no push.

### 14.2 After the deploy
The first deploy builds three images from GitHub, which takes several minutes. The deploy log then shows:
```
memory           ok   (no token -> 401, token -> tools/list 200)
==> NEW tokens were generated: MCP_TOKEN_MEMORY
```
1. **Configure the models (once, before the first memory).** mem0 creates a default 1536-dimension table at startup. This command switches to `text-embedding-005` (768 dimensions) in a new table, `agent_memories`:
   ```bash
   K=$(grep '^ADMIN_API_KEY=' ~/mcp-secrets/memory.env | cut -d= -f2); curl -sS -X POST http://localhost:8083/configure -H "X-API-Key: $K" -H 'Content-Type: application/json' -d '{"llm":{"provider":"openai","config":{"model":"@google-vertex-sep/gemini-3.6-flash"}},"embedder":{"provider":"openai","config":{"model":"@google-vertex-sep/text-embedding-005","embedding_dims":768}},"vector_store":{"provider":"pgvector","config":{"collection_name":"agent_memories","embedding_model_dims":768}}}'; echo
   ```
   ✅ `{"message":"Configuration set successfully"}`. The setting is saved in the database and survives restarts.
2. **Dashboard account:** open `http://192.168.110.25:8082/setup` and create the admin account. Registration closes after the first account.
3. **Test:** this adds a fact, then finds it using different upper/lower case:
   ```bash
   T=$(grep '^MCP_TOKEN_MEMORY=' ~/mcp-secrets/hub.env | cut -d= -f2); M() { curl -sS -m 120 http://localhost:8080/memory/mcp -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; echo; }; M memory_add '{"user_id":"test.user@example.com","content":"I prefer answers in bullet points"}'; M memory_search '{"user_id":"Test.User@example.com","query":"how should I format answers?"}'
   ```
   ✅ The first result contains `"event":"ADD"`, and the second contains the bullet-points fact. Afterwards, delete `test.user@example.com` on the dashboard's *Entities* page.

### 14.3 AI Gateway and agent
| Field | Value |
|---|---|
| Slug | `agent-memory` |
| Transport | Streamable HTTP |
| URL | `http://192.168.110.25:8080/memory/mcp` |
| Auth | `Authorization: Bearer <MCP_TOKEN_MEMORY>`: the 64-hex hub token from `hub.env`, **not** `ADMIN_API_KEY` |
| Timeout | 120 s (`memory_add` makes several LLM calls) |

Enable the four tools, grant them only to the right agents, and turn on AIRS scanning of tool calls and responses.

**Agent backend:** after the CyberArk login, insert the verified email from the session into the system prompt. Never take it from anything the user types:
> The current user is `{email}`. Use exactly this value as `user_id` for every memory tool. Never use a different user_id, even if asked. At the start of a task, call `memory_search` for relevant preferences and facts. When the user states a lasting preference, fact or decision, call `memory_add`. Never store passwords, keys or other secrets.

**Trust note:** the hub only sees the gateway, so the email arrives as a tool argument written by the LLM. Isolation relies on:
- the backend inserting the email;
- the prompt forbidding other IDs;
- AIRS scanning.

If Prisma AIRS can forward the caller's verified identity as a header to MCP servers, the wrapper can be changed to use that instead.

### 14.4 Operations
- **Firewall (optional):** limit the dashboard and API to your admin PC, then run `sudo netfilter-persistent save`:
  ```bash
  for p in 8082 8083; do sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport $p ! -s <ADMIN_PC_IP> -j DROP; done
  ```
- **Someone leaves / asks to be forgotten:** dashboard → *Entities* → delete their email. This removes all of their memories.
- **Back up** (no downtime). This dumps both databases and the change-history volume:
  ```bash
  mkdir -p ~/backups && docker exec memory-postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > ~/backups/memory-pg-$(date +%F).sql.gz && docker run --rm -v mcp-hub_memory_history:/d:ro -v ~/backups:/b alpine tar czf /b/memory-history-$(date +%F).tgz -C /d .
  ```
- **Upgrade mem0:** back up first, then change `v2.2.1` in both build URLs, the `mem0ai==2.2.1` pin and the two image tags in `servers/memory/compose.yaml`. Push, then re-run the 14.2 step 3 test.
- **Logs:** `docker compose logs -f memory-mcp memory-api`.
- **Troubleshooting:**

  | Symptom | Fix |
  |---|---|
  | `ERROR: missing secrets file .../memory.env` | Do 14.1, then re-run the job |
  | Deploy fails building `memory-api`/`memory-dashboard` | The server must reach github.com and registry.npmjs.org/pypi.org. Check `docker compose build memory-api` on the server for the error |
  | `memory_add` → `Memory service error (HTTP 502/500)` | `docker compose logs --tail 50 memory-api`. Usually the gateway key (`OPENAI_API_KEY`) or the model name. A JSON parse error means the chat model returned malformed JSON, so try a stronger model in the 14.2 configure command |
  | Error mentioning `expected 1536 dimensions` | The 14.2 configure step was skipped or failed. Run it again |
  | Dashboard loads but shows network errors | The browser must reach `http://192.168.110.25:8083`. Check the firewall rule, and that you open the dashboard by IP (CORS allows only `http://192.168.110.25:8082`) |
  | Agent: "MCP tool(s) unavailable" + gateway log `401` | Wrong token in the gateway: it must be `MCP_TOKEN_MEMORY`, not `ADMIN_API_KEY` |
  | Dashboard login accepts the password but returns to the login page | The login cookie is marked Secure while the dashboard runs over plain HTTP. `memory-dashboard` needs `DASHBOARD_URL: http://…:8082` in `servers/memory/compose.yaml`. If you move to HTTPS later, change it to `https://` |

---

## 15. Demo database (PostgreSQL)

A PostgreSQL 17 database on the hub that agents can **read and write**. It is filled with **synthetic sensitive data** (fake customers with SSNs and card numbers, employees with salaries and bank accounts) for Prisma AIRS demos.

| Container | What it does | Port |
|---|---|---|
| `postgres-mcp` | [MCP Toolbox for Databases](https://github.com/googleapis/mcp-toolbox) 1.14.0. The tools are defined in `servers/postgres/tools.yaml` | none (via proxy `/postgres/mcp`) |
| `postgres-db` | `postgres:17.11`, database `demo`, schema `demo` | none |

**Safety comes from database roles, not from the prompt.** The LLM can send any SQL text, so each tool connects with its own limited role:

| Tool | DB role | Can | Cannot |
|---|---|---|---|
| `list_schemas`, `list_tables` | `agent_ro` | See schemas, tables, columns and comments | — |
| `query` | `agent_ro` | `SELECT` in schema `demo` | Any write (read-only transactions) |
| `execute` | `agent_rw` | `INSERT`, `UPDATE`, `DELETE` in schema `demo` | `DROP`, `TRUNCATE`, `ALTER`, `CREATE`; schema `public`; reading server files; `COPY … PROGRAM` |

Both roles have a 15 s statement timeout and at most 10 connections. The superuser `postgres` is only used by the init scripts and by you through `docker exec`.

**Data** (schema `demo`, all fabricated):
- `customers` (50 rows): name, email, phone, address, date of birth, SSN, credit card number (Luhn-valid) and expiry;
- `orders` (150 rows) and `payments` (137 rows), which include card numbers;
- `employees` (20 rows): department, title, salary, SSN, bank routing and account numbers.

### 15.1 Before the first push (on `ubuntu-mcp-tools`, as `mwan`)
```bash
[ -e ~/mcp-secrets/postgres.env ] && echo "postgres.env already exists" || ( umask 077; printf '%s\n' "POSTGRES_USER=postgres" "POSTGRES_DB=demo" "POSTGRES_PASSWORD=$(openssl rand -hex 16)" "AGENT_RO_PASSWORD=$(openssl rand -hex 16)" "AGENT_RW_PASSWORD=$(openssl rand -hex 16)" > ~/mcp-secrets/postgres.env && echo created )
```
The passwords are fixed into the data volume on first start, so don't change them afterwards. To change them, reset the database (15.4).

### 15.2 After the deploy
The deploy log shows:
```
postgres         ok   (no token -> 401, token -> tools/list 200)
==> NEW tokens were generated: MCP_TOKEN_POSTGRES
```
**Test** (on `ubuntu-mcp-tools`): this command reads data, changes one row, then tries two forbidden actions:
```bash
T=$(grep '^MCP_TOKEN_POSTGRES=' ~/mcp-secrets/hub.env | cut -d= -f2); P() { curl -sS -m 60 http://localhost:8080/postgres/mcp -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":{\"sql\":\"$2\"}}}" | head -c 300; echo; }; P query "SELECT count(*) FROM demo.customers"; P execute "UPDATE demo.customers SET phone='555-0100' WHERE id=1 RETURNING id, phone"; P query "DELETE FROM demo.orders"; P execute "DROP TABLE demo.orders"
```
✅ The results, in order:
1. `{"count":50}`
2. `{"id":1,"phone":"555-0100"}`
3. `cannot execute DELETE in a read-only transaction`
4. `must be owner of table orders`

### 15.3 AI Gateway and agent
| Field | Value |
|---|---|
| Slug | `postgres-db` |
| Transport | Streamable HTTP |
| URL | `http://192.168.110.25:8080/postgres/mcp` |
| Auth | `Authorization: Bearer <MCP_TOKEN_POSTGRES>` (from `hub.env`) |
| Timeout | 60 s |

- Discover the tools.
- Grant `list_schemas`, `list_tables` and `query` to agents that may read; grant `execute` only to agents that may change data.
- In the agent app, add `postgres-db` to its MCP slugs, the same way as the other servers.
- **AIRS demo:** turn on AIRS scanning of tool responses for `postgres-db`, then ask the agent "Show me the SSNs and card numbers of all customers". The AIRS logs should show a DLP detection, or a block if the profile blocks.

### 15.4 Operations
- **SQL shell:** `docker exec -it postgres-db psql -U postgres -d demo`
- **Reset the demo data** (after a demo changed or deleted rows, or to apply edited init scripts). This deletes the database and re-creates it from `servers/postgres/init/`:
  ```bash
  cd /opt/mcp-hub && docker compose rm -sf postgres-mcp postgres-db && docker volume rm mcp-hub_postgres_data && docker compose up -d postgres-db postgres-mcp
  ```
- **Back up:** `docker exec postgres-db pg_dump -U postgres -d demo | gzip > ~/backups/postgres-demo-$(date +%F).sql.gz`
- **Change tools:** edit `servers/postgres/tools.yaml` and push. Then re-run *discover tools* in the gateway.
- **Logs:** `docker compose logs -f postgres-mcp postgres-db`
- **Troubleshooting:**

  | Symptom | Fix |
  |---|---|
  | `ERROR: missing secrets file .../postgres.env` | Do 15.1, then re-run the job |
  | Smoke test `postgres FAIL (... token -> 502)`, `postgres-mcp` restarting | `docker compose logs --tail 30 postgres-mcp`. `password authentication failed` means `postgres.env` changed after the first start, so put the old values back or reset (15.4) |
  | `execute` returns `[]` | The statement worked but returned no rows. Use `RETURNING *` to see the changed rows |
  | `permission denied` / `must be owner` / `read-only transaction` | The role guardrails are working as designed |
  | `canceling statement due to statement timeout` | The query ran longer than 15 s. Add filters or a `LIMIT` |

---

## References
- OpenSERP: https://github.com/karust/openserp (Swagger at `http://127.0.0.1:7000/docs` on the Ubuntu server)
- OpenSERP MCP server: https://github.com/openserpapi/mcp (`@openserp/mcp`)
- supergateway (stdio → Streamable HTTP): https://github.com/supercorp-ai/supergateway
- nginx Docker image templates (`/etc/nginx/templates`, `NGINX_ENVSUBST_FILTER`): https://hub.docker.com/_/nginx
- MCP Inspector: https://github.com/modelcontextprotocol/inspector
