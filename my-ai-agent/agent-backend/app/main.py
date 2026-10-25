import os
import io
import json
import re
import logging
import asyncio
import uuid
import httpx
from contextlib import asynccontextmanager
import jwt
import pandas as pd
import docx
import base64
from pdf2image import convert_from_bytes
from pypdf import PdfReader
from jwt import PyJWKClient
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException, status, Request, File, UploadFile, Form
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from redis import asyncio as aioredis
from openai import AsyncOpenAI
from dotenv import load_dotenv
from typing import Optional

import tools
import a2a_agents

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
logger = logging.getLogger(__name__)


def accumulate_tool_call_delta(tc, tool_calls_dict: dict, index_to_key: dict) -> None:
    """
    Merge one streamed tool-call delta fragment into tool_calls_dict.

    OpenAI/DeepSeek keep tc.index stable and unique per parallel tool call, so
    fragments naturally correlate by index. Gemini (via Portkey's OpenAI-compat
    translation) instead sends index=0 for every parallel tool call in a turn,
    each arriving as a single complete fragment with its own id. Blindly keying
    by index merges those into one corrupted entry (name/args from different
    calls concatenated). Detect a new tc.id reusing an index already bound to a
    different id and give it its own slot instead of clobbering the original.
    """
    idx = tc.index
    tc_id = getattr(tc, 'id', None)
    func = getattr(tc, 'function', None)
    name = getattr(func, 'name', None) if func else None
    arguments = getattr(func, 'arguments', None) if func else None

    if tc_id:
        current_key = index_to_key.get(idx)
        if current_key is not None and tool_calls_dict[current_key]["id"] != tc_id:
            key = (idx, tc_id)
        else:
            key = current_key if current_key is not None else idx
        index_to_key[idx] = key
        entry = tool_calls_dict.setdefault(key, {"id": tc_id, "name": "", "arguments": ""})
        entry["id"] = tc_id
    else:
        key = index_to_key.get(idx, idx)
        entry = tool_calls_dict.setdefault(key, {"id": f"call_{uuid.uuid4().hex[:8]}", "name": "", "arguments": ""})

    if name:
        entry["name"] = name
    if arguments:
        entry["arguments"] += arguments

# Unicode box-drawing / diagram-arrow characters. Deliberately excludes plain
# ASCII '-', '|', '+' (too common in ordinary prose/code) and plain arrows like
# '→' (used inline in normal sentences, e.g. "coding → one route") — those
# would false-positive on regular text. This set is rare outside diagrams.
_DIAGRAM_CHARS = set("┌┐└┘├┤┬┴┼─│═║╔╗╚╝╠╣╦╩╬▲▼►◄")

_FENCE_LINE_RE = re.compile(r'^`{3,}[^`]*$')

class DiagramFencer:
    """
    Wraps runs of ASCII/box-drawing diagram lines in ``` fences as they stream,
    since markdown collapses un-fenced line breaks and models don't reliably
    fence their own diagrams. Decides fence transitions at the first
    non-whitespace character of each line, so ordinary prose (the vast
    majority of output) passes through with no added latency — only a line
    whose first real character is a box-drawing char (or a backtick, to check
    for a fence marker) pays a buffering cost of a few leading characters. A
    diagram line indented with plain text before any box character (rare)
    won't be caught until a later line.

    Tracks whether we're already inside a fence the MODEL itself emitted
    (a line of 3+ backticks) and suppresses its own fencing while inside one —
    injecting a second, unmatched ``` right after the model's own opener
    breaks CommonMark's fence matching (the pair collapses into an empty
    block) and un-fences everything that follows, which is worse than doing
    nothing.
    """
    def __init__(self):
        self._in_block = False
        self._in_model_fence = False
        self._awaiting_first_char = True
        self._ws_prefix = ""
        self._buffering_fence_line = False
        self._fence_line_buf = ""
        self._last_emitted_char = "\n"

    def _resolve_fence_candidate(self, line_with_nl: str) -> str:
        if _FENCE_LINE_RE.match(line_with_nl.strip()):
            self._in_model_fence = not self._in_model_fence
        out = self._ws_prefix + line_with_nl
        self._ws_prefix = ""
        if out:
            self._last_emitted_char = out[-1]
        return out

    def feed(self, chunk: str) -> str:
        out = []
        for ch in chunk:
            if self._buffering_fence_line:
                self._fence_line_buf += ch
                if ch == '\n':
                    out.append(self._resolve_fence_candidate(self._fence_line_buf))
                    self._fence_line_buf = ""
                    self._buffering_fence_line = False
                    self._awaiting_first_char = True
                continue
            if self._awaiting_first_char:
                if ch == '\n':
                    out.append(self._ws_prefix)
                    out.append(ch)
                    self._ws_prefix = ""
                    self._last_emitted_char = ch
                    continue
                if ch.isspace():
                    self._ws_prefix += ch
                    continue
                if ch == '`':
                    self._buffering_fence_line = True
                    self._fence_line_buf = ch
                    continue
                if not self._in_model_fence:
                    is_diagram = ch in _DIAGRAM_CHARS
                    if is_diagram and not self._in_block:
                        out.append("```\n")
                        self._in_block = True
                    elif not is_diagram and self._in_block:
                        out.append("```\n")
                        self._in_block = False
                out.append(self._ws_prefix)
                self._ws_prefix = ""
                out.append(ch)
                self._last_emitted_char = ch
                self._awaiting_first_char = False
                continue
            out.append(ch)
            self._last_emitted_char = ch
            if ch == '\n':
                self._awaiting_first_char = True
        return "".join(out)

    def flush(self) -> str:
        out = ""
        if self._buffering_fence_line:
            out += self._resolve_fence_candidate(self._fence_line_buf)
            self._fence_line_buf = ""
            self._buffering_fence_line = False
        if self._ws_prefix:
            out += self._ws_prefix
            self._last_emitted_char = self._ws_prefix[-1]
            self._ws_prefix = ""
        if self._in_block:
            # A closing ``` must stand alone on its own line — if the last
            # character actually emitted wasn't a newline (e.g. this flush is
            # closing off content abandoned mid-line at a discard boundary),
            # start one before the fence marker so it's a valid delimiter
            # rather than text glued onto the fence line.
            if self._last_emitted_char != "\n":
                out += "\n"
            out += "```\n"
            self._last_emitted_char = "\n"
            self._in_block = False
        return out

    def reset(self) -> str:
        """
        Call at a hard content-stream boundary where the content just fed in
        is being abandoned mid-way (e.g. the model started a sentence, or even
        opened a fence, then pivoted to a tool call instead of finishing it).
        Closes off anything left dangling from that abandoned content — same
        as flush() — and additionally clears _in_model_fence/_awaiting_first_char,
        since those track state *within* the abandoned content and must not
        leak into the unrelated content that follows (otherwise a truncated
        "```" the model never closed permanently disables our own fencing for
        the rest of the turn, or a half-finished line suppresses detection of
        a genuine diagram at the start of the next iteration's first line).
        """
        out = self.flush()
        self._in_model_fence = False
        self._awaiting_first_char = True
        return out

def fence_diagram_blocks(text: str) -> str:
    fencer = DiagramFencer()
    return fencer.feed(text) + fencer.flush()

app = FastAPI(title="Managed AI Agent")

CORS_ALLOWED_ORIGINS = [o.strip() for o in os.getenv("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ALLOWED_ORIGINS,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["*"],
)

# Configuration
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
SESSION_TTL = 3600

PORTKEY_GATEWAY_URL = os.getenv("PORTKEY_GATEWAY_URL", "http://192.168.110.25:8787/v1")
PORTKEY_API_KEY = os.getenv("PORTKEY_API_KEY", "")
# MCP servers are hosted behind the AI Gateway's own MCP port — a different
# host:port from the chat-completions gateway above, not derived from it.
PORTKEY_MCP_GATEWAY_URL = os.getenv("PORTKEY_MCP_GATEWAY_URL", "")
PORTKEY_MCP_SERVER_SLUGS_DEFAULT = [s.strip() for s in os.getenv("PORTKEY_MCP_SERVER_SLUGS", "").split(",") if s.strip()]

# The actual model is selected by the AI Gateway's own routing config, not by this app —
# the completions API still requires a non-empty `model` string, so this is a placeholder.
GATEWAY_MODEL = "default"

CYBERARK_ISSUER = os.getenv("CYBERARK_ISSUER")
CYBERARK_AUDIENCE = os.getenv("CYBERARK_AUDIENCE")
CYBERARK_JWKS_URI = os.getenv("CYBERARK_JWKS_URI")

# "user1:pass1,user2:pass2" -> {"user1": "pass1", "user2": "pass2"}
BASIC_AUTH_USERS = dict(
    pair.split(":", 1) for pair in os.getenv("BASIC_AUTH_USERS", "").split(",") if ":" in pair
)

redis_client = aioredis.from_url(REDIS_URL)

class ChatRequest(BaseModel):
    text: str
    session_id: str | None = None
    user_info: dict | None = None  # {"id", "email", "name"} from the CyberArk Identity (Idira) or Basic Auth session
    task_type: str | None = None  # "coding" | "writing", chosen by the user in the client UI

jwks_client = PyJWKClient(CYBERARK_JWKS_URI)

def validate_jwt(token: str):
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        payload = jwt.decode(token, signing_key.key, algorithms=["RS256"], audience=CYBERARK_AUDIENCE, issuer=CYBERARK_ISSUER)
        return payload
    except Exception as e:
        logger.error(f"JWT Validation Failed: {str(e)}")
        raise e

def validate_basic_auth(token: str) -> dict:
    """token is the base64 payload after the 'Basic ' scheme prefix."""
    try:
        decoded = base64.b64decode(token).decode("utf-8")
        username, _, password = decoded.partition(":")
    except Exception as e:
        raise ValueError("Malformed Basic Auth token") from e

    if not username or BASIC_AUTH_USERS.get(username) != password:
        raise ValueError("Invalid Basic Auth credentials")

    return {"sub": username, "auth_method": "basic"}

_idira_userinfo_endpoint: str | None = None

async def _get_idira_userinfo_endpoint() -> str | None:
    global _idira_userinfo_endpoint
    if _idira_userinfo_endpoint is None:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{CYBERARK_ISSUER.rstrip('/')}/.well-known/openid-configuration")
            resp.raise_for_status()
            _idira_userinfo_endpoint = resp.json().get("userinfo_endpoint")
    return _idira_userinfo_endpoint

async def resolve_verified_email(claims: dict, access_token: str | None = None) -> str | None:
    """The user's email from the *verified* token only — never from the request
    body's user_info, which the client controls. Used as identity for per-user
    MCP tools (agent-memory). Returns None when there's no verifiable email."""
    if claims.get("auth_method") == "basic":
        return None
    email = claims.get("email")
    if email:
        return email.strip().lower()

    # Access token has no email claim: ask Idira's userinfo endpoint, cached per user.
    sub = claims.get("sub")
    if not access_token or not sub:
        return None
    cache_key = f"userinfo_email:{sub}"
    try:
        cached = await redis_client.get(cache_key)
        if cached:
            return cached.decode("utf-8")
        endpoint = await _get_idira_userinfo_endpoint()
        if not endpoint:
            return None
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(endpoint, headers={"Authorization": f"Bearer {access_token}"})
            resp.raise_for_status()
            email = (resp.json().get("email") or "").strip().lower()
        if email:
            await redis_client.set(cache_key, email, ex=3600)
        return email or None
    except Exception as e:
        logger.warning(f"Idira userinfo email lookup failed: {e}")
        return None

async def verify_request_auth(request: Request):
    auth_header = request.headers.get("Authorization")
    if not auth_header or " " not in auth_header:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid token scheme")

    scheme, _, token = auth_header.partition(" ")
    try:
        if scheme == "Basic":
            claims = validate_basic_auth(token)
        elif scheme == "Bearer":
            claims = validate_jwt(token)
        else:
            raise ValueError(f"Unsupported auth scheme: {scheme}")
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")

    claims["verified_email"] = await resolve_verified_email(claims, token if scheme == "Bearer" else None)
    return claims

MARKDOWN_FORMATTING_GUARDRAIL = (
    "\n\nFormatting rule: when your response includes an ASCII/box-drawing diagram, "
    "an indentation- or alignment-sensitive layout, or a table not made with markdown "
    "pipe syntax, always wrap it in a triple-backtick fenced code block. Content outside "
    "a code fence is rendered as normal markdown prose, which collapses single line "
    "breaks and whitespace — without a fence, diagrams and aligned text will render "
    "garbled."
)

def _enabled_mcp_slugs(servers_raw: bytes | None, legacy_raw: bytes | None) -> list[str]:
    """config:mcp_servers (dashboard's MCP Servers tab) → legacy comma-separated
    config:mcp_server_slugs → env default. A saved empty/all-disabled list means
    no MCP servers, not "fall back"."""
    if servers_raw:
        try:
            return [s["slug"] for s in json.loads(servers_raw) if s.get("enabled") and s.get("slug")]
        except (ValueError, TypeError, KeyError, AttributeError):
            logger.warning("config:mcp_servers is malformed; falling back to legacy/env MCP slugs")
    if legacy_raw:
        slugs = [s.strip() for s in legacy_raw.decode('utf-8').split(",") if s.strip()]
        if slugs:
            return slugs
    return PORTKEY_MCP_SERVER_SLUGS_DEFAULT

def _enabled_a2a_agents(raw: bytes | None) -> list[dict]:
    """config:a2a_agents (dashboard's Sub-agents tab): enabled {slug, url, card_url} entries.
    card_url is an optional override for where to read the agent card; empty means
    {url}/.well-known/agent-card.json."""
    if not raw:
        return []
    try:
        return [
            {"slug": a["slug"], "url": a["url"], "card_url": a.get("card_url") or None}
            for a in json.loads(raw)
            if a.get("enabled") and a.get("slug") and a.get("url")
        ]
    except (ValueError, TypeError, KeyError, AttributeError):
        logger.warning("config:a2a_agents is malformed; no sub-agents loaded")
        return []

async def get_live_config():
    try:
        system_p = await redis_client.get("config:system_prompt")
        vision_capable_raw = await redis_client.get("config:vision_capable")
        gateway_url_cfg = await redis_client.get("config:gateway_url")
        gateway_api_key_cfg = await redis_client.get("config:gateway_api_key")
        mcp_api_key_cfg = await redis_client.get("config:mcp_api_key")
        mcp_gateway_url_cfg = await redis_client.get("config:mcp_gateway_url")
        mcp_servers_raw = await redis_client.get("config:mcp_servers")
        mcp_slugs_raw = await redis_client.get("config:mcp_server_slugs")
        a2a_agents_raw = await redis_client.get("config:a2a_agents")

        mcp_server_slugs = _enabled_mcp_slugs(mcp_servers_raw, mcp_slugs_raw)

        base_prompt = system_p.decode('utf-8') if system_p else "You are a helpful AI assistant."
        return {
            "system_prompt": base_prompt + MARKDOWN_FORMATTING_GUARDRAIL,
            "vision_capable": vision_capable_raw.decode('utf-8') == "true" if vision_capable_raw else False,
            "gateway_url": gateway_url_cfg.decode('utf-8') if gateway_url_cfg else PORTKEY_GATEWAY_URL,
            "gateway_api_key": gateway_api_key_cfg.decode('utf-8') if gateway_api_key_cfg else PORTKEY_API_KEY,
            "mcp_api_key": mcp_api_key_cfg.decode('utf-8') if mcp_api_key_cfg else "",
            "mcp_gateway_url": mcp_gateway_url_cfg.decode('utf-8') if mcp_gateway_url_cfg else PORTKEY_MCP_GATEWAY_URL,
            "mcp_server_slugs": mcp_server_slugs,
            "a2a_agents": _enabled_a2a_agents(a2a_agents_raw),
        }
    except Exception as e:
        return {"system_prompt": "You are a helpful AI assistant." + MARKDOWN_FORMATTING_GUARDRAIL, "vision_capable": False, "gateway_url": PORTKEY_GATEWAY_URL, "gateway_api_key": PORTKEY_API_KEY, "mcp_api_key": "", "mcp_gateway_url": PORTKEY_MCP_GATEWAY_URL, "mcp_server_slugs": PORTKEY_MCP_SERVER_SLUGS_DEFAULT, "a2a_agents": []}


# ==========================================
# MCP SESSION LIFECYCLE
# MCP servers are hosted behind the AI Gateway's own MCP port (mcp_gateway_url,
# separate from the chat-completions gateway_url), reached by slug at
# {mcp_gateway_url}/{slug}/mcp.
# ==========================================

@asynccontextmanager
async def mcp_sessions_context(config: dict, user_email: str | None = None, session_id: str | None = None):
    """Opens AI Gateway MCP sessions for all configured slugs and resolves enabled A2A
    sub-agents (a2a_agents.py), yields (merged_tool_schemas, open_sessions, failed_slugs),
    then closes everything on exit. A2A entries share the sessions dict under "a2a:{slug}"
    keys. failed_slugs is [{"slug": str, "error": str}] for anything still unavailable
    after retries — callers should surface this to the user instead of silently
    proceeding as if no tools were needed. session_id scopes each sub-agent's
    conversation to this chat."""
    slugs = config.get("mcp_server_slugs")
    mcp_gateway_url = config.get("mcp_gateway_url")
    gateway_api_key = config.get("gateway_api_key") or PORTKEY_API_KEY
    # Separate from gateway_api_key so MCP auth (e.g. a lab token pointed straight at
    # mcp-hub) can be changed without affecting LLM chat-completions routing, which
    # always uses gateway_api_key via get_llm_client(). Falls back to gateway_api_key
    # when unset, matching the pre-existing shared-key behavior.
    mcp_api_key = config.get("mcp_api_key") or gateway_api_key

    async def _no_mcp():
        return [], {}, []

    mcp_load = (
        tools.get_mcp_tool_schemas(slugs, mcp_gateway_url, mcp_api_key, user_email=user_email)
        if slugs and mcp_gateway_url else _no_mcp()
    )
    a2a_load = a2a_agents.load_a2a_tools(
        config.get("a2a_agents") or [], gateway_api_key, redis_client, session_id, SESSION_TTL
    )
    (mcp_schemas, open_sessions, failed_slugs), (a2a_schemas, a2a_entries, a2a_failures) = await asyncio.gather(
        mcp_load, a2a_load
    )
    open_sessions.update(a2a_entries)
    try:
        yield mcp_schemas + a2a_schemas, open_sessions, failed_slugs + a2a_failures
    finally:
        for entry in open_sessions.values():
            try:
                await entry["stack"].aclose()
            except Exception:
                pass


# ==========================================
# PORTKEY ROUTING METADATA
# ==========================================
def build_portkey_metadata(task_type: str | None, user_info: dict | None) -> str:
    """Builds the x-portkey-metadata JSON payload from the user's chosen task type."""
    meta = {"task_type": task_type if task_type in ("coding", "writing") else "writing"}
    if user_info:
        meta["user_id"] = user_info.get("id", "")
        meta["user_email"] = user_info.get("email", "")
        meta["user_name"] = user_info.get("name", "")
        # Portkey's special indexed field — powers "Rated by" on the feedback view.
        if user_info.get("name"):
            meta["_user"] = user_info["name"]
    return json.dumps(meta)


def get_llm_client(config: dict = None) -> AsyncOpenAI:
    """Returns a client routed through the configured AI gateway."""
    config = config or {}
    pk_base_url = config.get("gateway_url") or PORTKEY_GATEWAY_URL
    portkey_api_key = config.get("gateway_api_key") or PORTKEY_API_KEY
    headers = {"x-portkey-api-key": portkey_api_key}
    return AsyncOpenAI(api_key="dummy_key", base_url=pk_base_url, default_headers=headers)

def extract_portkey_activity(raw_response, parsed_response=None, stream_model: str = "", label: str = "") -> dict:
    """
    Extract a single LLM activity dict from a Portkey response.
    Returns a dict with keys: label, model, provider, prompt_tokens,
    completion_tokens, cache, retry.
    """
    try:
        headers = raw_response.http_response.headers
        cache = headers.get("x-portkey-cache-status", "")
        retry = headers.get("x-portkey-retry-attempt-count", "0")
        provider = headers.get("x-portkey-provider", "")

        model_used = stream_model
        if not model_used and parsed_response is not None:
            try:
                model_used = getattr(parsed_response, 'model', '') or ""
            except Exception:
                pass

        prompt_tokens = completion_tokens = 0
        if parsed_response is not None:
            try:
                if hasattr(parsed_response, 'prompt_tokens'):
                    prompt_tokens = getattr(parsed_response, 'prompt_tokens', 0) or 0
                    completion_tokens = getattr(parsed_response, 'completion_tokens', 0) or 0
                else:
                    usage = getattr(parsed_response, 'usage', None)
                    if usage:
                        prompt_tokens = getattr(usage, 'prompt_tokens', 0) or 0
                        completion_tokens = getattr(usage, 'completion_tokens', 0) or 0
            except Exception:
                pass

        if not (prompt_tokens or completion_tokens):
            try:
                prompt_tokens = int(headers.get("x-portkey-prompt-tokens", 0) or 0)
                completion_tokens = int(headers.get("x-portkey-completion-tokens", 0) or 0)
            except Exception:
                pass

        return {
            "label": label,
            "model": model_used,
            "provider": provider,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "cache": cache,
            "retry": retry,
        }
    except Exception as e:
        logger.error(f"extract_portkey_activity failed: {e}")
        return {}


def format_portkey_activities(activities: list, trace_id: str = "") -> str:
    """
    Format a list of LLM activity dicts into a numbered multiline string.
    Each activity is one numbered line. Trace ID shown once at the end.
    """
    lines = []
    for i, act in enumerate(activities, 1):
        parts = []
        if act.get("model"):
            parts.append(f"**{act['model']}**")
        if act.get("provider"):
            parts.append(f"via {act['provider']}")
        pt = act.get("prompt_tokens", 0)
        ct = act.get("completion_tokens", 0)
        if pt or ct:
            parts.append(f"↑{pt} ↓{ct} tokens")
        if act.get("cache", "").upper() == "HIT":
            parts.append("📦 cached")
        retry = act.get("retry", "0")
        if retry and retry not in ("0", ""):
            parts.append(f"retried {retry}×")
        label = act.get("label", "")
        prefix = f"{i}. {label}: " if label else f"{i}. "
        lines.append(prefix + ", ".join(parts))
    if trace_id:
        lines.append(f"Trace ID: `{trace_id}`")
    return "\n".join(lines)


def extract_portkey_routing_info(raw_response, parsed_response=None, stream_model: str = "", trace_id: str = "") -> str:
    """Backwards-compatible single-activity formatter."""
    act = extract_portkey_activity(raw_response, parsed_response, stream_model)
    if not any([act.get("model"), act.get("provider"), act.get("prompt_tokens"), act.get("completion_tokens")]):
        return ""
    return format_portkey_activities([act], trace_id=trace_id)

async def extract_text_from_file(file: UploadFile) -> str:
    """Extracts text content from uploaded files based on their extension."""
    content = await file.read()
    filename = file.filename.lower()
    
    try:
        # --- DATA FILES (CSV, EXCEL) ---
        if filename.endswith((".csv", ".xlsx", ".xls")):
            if filename.endswith(".csv"):
                df = pd.read_csv(io.BytesIO(content))
            else:
                df = pd.read_excel(io.BytesIO(content))
            return f"### Contents of {file.filename}:\n\n" + df.to_markdown(index=False)
            
        # --- WORD DOCUMENTS ---
        elif filename.endswith(".docx"):
            doc = docx.Document(io.BytesIO(content))
            text = f"### Contents of {file.filename}:\n\n"
            for para in doc.paragraphs:
                if para.text.strip():  # Only add paragraphs that actually contain text
                    text += para.text + "\n"
            return text
            
        # --- PDF FILES ---
        elif filename.endswith(".pdf"):
            # Convert the PDF pages into actual images
            images = convert_from_bytes(content)
    
            pdf_messages = []
            for img in images:
                # Convert each page image to a Base64 string
                buffered = io.BytesIO()
                img.save(buffered, format="JPEG")
                b64_img = base64.b64encode(buffered.getvalue()).decode('utf-8')
                
                # Format it exactly like a native image upload for Gemma 4
                pdf_messages.append({
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{b64_img}"}
                })
    
            return pdf_messages # Return the array of image objects instead of text!
            
        # --- TEXT & CODING FILES ---
        elif filename.endswith((
            ".txt", ".md", ".json", ".py", ".js", ".ts", ".html", ".css", 
            ".java", ".cpp", ".c", ".cs", ".go", ".rs", ".sh", ".yaml", ".yml", ".xml"
        )):
            decoded_text = content.decode('utf-8')
            return f"### Contents of {file.filename}:\n\n```\n{decoded_text}\n```"
            
        # --- IMAGE FILES ---
        elif filename.endswith((".png", ".jpg", ".jpeg")):
            b64_img = base64.b64encode(content).decode('utf-8')
            mime = file.content_type or ("image/png" if filename.endswith(".png") else "image/jpeg")
            return [{"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64_img}"}}]
            
        else:
            return f"Error: Unsupported file format '{filename}'."
            
    except UnicodeDecodeError:
        logger.error(f"Encoding error parsing file {filename}")
        return f"Error: {file.filename} appears to be a binary file or uses an unsupported encoding."
    except Exception as e:
        logger.error(f"Error parsing file {filename}: {str(e)}")
        return f"Error reading file {file.filename}: {str(e)}"

class FeedbackRequest(BaseModel):
    trace_id: str
    value: int  # 1–5 star rating sent directly to Portkey
    feedback_id: Optional[str] = None
    user_info: dict | None = None  # {"id", "email", "name"} from the CyberArk Identity (Idira) or Basic Auth session

@app.get("/api/v1/client-config")
async def get_client_config():
    """Public endpoint — returns settings the chat UI needs on load."""
    conn = await redis_client.get("config:connection_method")
    return {
        "connection_method": conn.decode("utf-8") if conn else "websocket",
    }

@app.post("/api/v1/auth/basic/verify")
async def verify_basic_auth_endpoint(request: Request):
    """
    Validates Basic Auth credentials at login time (called by the client UI's
    NextAuth Credentials provider) so bad logins are rejected before a session
    is issued, instead of only failing on the first chat request.
    """
    auth_header = request.headers.get("Authorization", "")
    scheme, _, token = auth_header.partition(" ")
    if scheme != "Basic":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing Basic Auth credentials")
    try:
        validate_basic_auth(token)
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    return {"status": "ok"}

@app.post("/api/v1/feedback")
async def submit_feedback(req: FeedbackRequest):
    """Forward user feedback (1-10 star rating) to Portkey."""

    headers = {
        "x-portkey-api-key": PORTKEY_API_KEY,
        "Content-Type": "application/json"
    }
    custom_metadata = {"source": "user_rating"}
    if req.user_info and req.user_info.get("name"):
        custom_metadata["_user"] = req.user_info["name"]

    async with httpx.AsyncClient() as client:
        if req.feedback_id:
            response = await client.put(
                f"https://api.portkey.ai/v1/feedback/{req.feedback_id}",
                headers=headers,
                json={"value": req.value, "metadata": custom_metadata}
            )
        else:
            response = await client.post(
                "https://api.portkey.ai/v1/feedback",
                headers=headers,
                json={"trace_id": req.trace_id, "value": req.value, "metadata": custom_metadata}
            )

    if response.status_code == 200:
        data = response.json()
        logger.info(f"Portkey feedback response: {data}")
        return {"status": "success", "data": data}
    else:
        logger.error(f"Portkey feedback error: {response.status_code} {response.text}")
        return {"status": "error", "message": response.text}


# ==========================================
# FILE UPLOAD ENDPOINT
# ==========================================
@app.post("/api/v1/upload")
async def upload_file_endpoint(
    file: UploadFile = File(...),
    session_id: str = Form(...),
    token_payload: dict = Depends(verify_request_auth)
):
    logger.info(f"Received file upload: {file.filename} for session: {session_id}")
    
    extracted_content = await extract_text_from_file(file)
    
    redis_key = f"session:{session_id}"
    raw_history = await redis_client.get(redis_key)
    
    config = await get_live_config()
    messages = json.loads(raw_history) if raw_history else [{"role": "system", "content": config["system_prompt"]}]
    
    # --- MULTIMODAL INJECTION (PDFs & Images) ---
    if isinstance(extracted_content, list):
        is_vision_model = config.get("vision_capable", False)
        if not is_vision_model:
            messages.append({"role": "user", "content": f"I tried to upload an image file named '{file.filename}'."})
            messages.append({"role": "assistant", "content": f"I can see you uploaded '{file.filename}', but the active model is not marked as vision-capable. Please mark it as vision-capable in the admin dashboard to analyze images."})
            upload_status = "unsupported_model"
        else:
            content_array = [{"type": "text", "text": f"I have uploaded a visual file named '{file.filename}'. Please analyze the attached images."}]
            content_array.extend(extracted_content)
            messages.append({"role": "user", "content": content_array})
            messages.append({"role": "assistant", "content": f"I have received the visual file '{file.filename}'. How can I help you analyze it?"})
            upload_status = "success"

    # --- TEXT INJECTION (Code, CSV, Word, TXT) ---
    else:
        file_message = f"I have uploaded a file named '{file.filename}'. Here is its content for your reference:\n\n{extracted_content}"
        messages.append({"role": "user", "content": file_message})
        messages.append({"role": "assistant", "content": f"I have received and read the file '{file.filename}'. How can I help you with it?"})
        upload_status = "success"

    await redis_client.setex(redis_key, SESSION_TTL, json.dumps(messages))
    return {"status": upload_status, "message": f"File {file.filename} processed successfully.", "session_id": session_id}



# ==========================================
# AGENTIC RAG — REACT TOOL LOOP HELPER
# ==========================================
async def run_react_loop(
    active_client, actual_model, messages, tool_schemas,
    current_trace_id, portkey_metadata,
    on_tool_start=None, on_tool_done=None, on_content=None, on_discard=None,
    max_iterations=15,
    mcp_sessions=None,
):
    """
    ReAct (Reason + Act) loop for Agentic RAG.

    Every iteration uses a streaming call. Tool call chunks are buffered silently.
    Content chunks are emitted live via on_content as soon as they arrive, before
    it's known whether this iteration will turn into a tool call (some models
    stream a bit of prose before deciding to call a tool). If tool calls are
    found in the stream, that content is discarded from final_text and tools
    execute — but it was already forwarded via on_content, so on_discard fires
    at that point to let the caller undo any stateful side effects (e.g. close
    a code fence it speculatively opened) before the next iteration's content
    arrives. If no tool calls, the streamed content IS the final answer —
    already delivered live.

    on_content(chunk: str) — called for each streamed token of the final answer.
    on_discard() — called when a call already forwarded via on_content turns out
    to be a tool-call iteration and is being discarded from final_text.
    Appends tool-call/tool-result turns to `messages` but not the final answer;
    the caller appends that itself before saving the session.
    Returns (final_text, iterations_used, prompt_tokens, completion_tokens, activity_log).
    """
    final_text = ""
    iterations_used = 0
    accumulated_prompt_tokens = 0
    accumulated_completion_tokens = 0
    activity_log = []  # list of activity dicts, one per LLM call
    seen_tool_calls = {}  # canonical "name::sorted-args" -> result, dedupes repeated calls

    for iteration in range(1, max_iterations + 1):
        # On the last allowed iteration, force a plain-text answer instead of
        # letting the model keep calling tools — guarantees the loop can never
        # exhaust its budget and return an empty response.
        is_last_iteration = iteration == max_iterations
        # On the last iteration keep the tool definitions but forbid calling them
        # (tool_choice="none"). Dropping the tools entirely is weaker: with a history
        # full of tool calls, some models keep calling tools anyway (cutting their answer
        # short) and some providers reject tool turns with no tools declared.
        tool_kwargs = {"tools": tool_schemas} if tool_schemas else {}
        if tool_schemas and is_last_iteration:
            tool_kwargs["tool_choice"] = "none"

        raw_iter = await active_client.chat.completions.with_raw_response.create(
            model=actual_model,
            messages=messages,
            **tool_kwargs,
            stream=True,
            stream_options={"include_usage": True},
            extra_headers={
                "x-portkey-trace-id": current_trace_id,
                "x-portkey-metadata": portkey_metadata,
            }
        )
        stream_resp = raw_iter.parse()

        # Accumulate both content and tool calls from the stream simultaneously
        content_chunks = []
        tool_calls_dict = {}
        tool_call_index_to_key = {}
        finish_reason = None
        iter_model_used = ""

        async for chunk in stream_resp:
            # Capture usage from usage-only final chunk (stream_options=include_usage)
            if not chunk.choices:
                if getattr(chunk, 'usage', None):
                    u = chunk.usage
                    accumulated_prompt_tokens += getattr(u, 'prompt_tokens', 0) or 0
                    accumulated_completion_tokens += getattr(u, 'completion_tokens', 0) or 0
                continue
            choice = chunk.choices[0]
            if not choice:
                continue

            delta = choice.delta
            finish_reason = choice.finish_reason or finish_reason

            # Accumulate tool call fragments
            if getattr(delta, 'tool_calls', None):
                for tc in delta.tool_calls:
                    logger.info(f"🔬 RAW TOOL_CALL DELTA (loop): index={tc.index!r} id={getattr(tc, 'id', None)!r} function={getattr(tc, 'function', None)!r}")
                    accumulate_tool_call_delta(tc, tool_calls_dict, tool_call_index_to_key)

            # Stream content live if no tool calls seen yet in this iteration
            if getattr(delta, 'content', None):
                content_chunks.append(delta.content)
                # Only emit live if this looks like a final turn (no tool calls so far).
                # On the last iteration tool calls are ignored, so all its text is the
                # answer: keep streaming it, or the user sees it cut off mid-sentence.
                if (not tool_calls_dict or is_last_iteration) and on_content is not None:
                    await on_content(delta.content)

            # Capture model name from any chunk that carries it
            if getattr(chunk, 'model', None):
                iter_model_used = chunk.model

            # Some providers (Bedrock) embed usage in regular content chunks, not a separate usage-only chunk
            if getattr(chunk, 'usage', None):
                u = chunk.usage
                accumulated_prompt_tokens += getattr(u, 'prompt_tokens', 0) or 0
                accumulated_completion_tokens += getattr(u, 'completion_tokens', 0) or 0

        # Capture per-iteration activity for Portkey metadata
        iter_pt = accumulated_prompt_tokens
        iter_ct = accumulated_completion_tokens
        accumulated_prompt_tokens = 0
        accumulated_completion_tokens = 0
        class _IterUsage:
            prompt_tokens = iter_pt
            completion_tokens = iter_ct
        if tool_calls_dict:
            iter_label = "Tool call"
        elif is_last_iteration:
            iter_label = "Forced synthesis (iteration cap reached)"
        else:
            iter_label = "Synthesis"
        act = extract_portkey_activity(
            raw_iter,
            parsed_response=_IterUsage() if (iter_pt or iter_ct) else None,
            stream_model=iter_model_used,
            label=iter_label
        )
        activity_log.append(act)

        # After stream ends: did we get tool calls?
        # On the forced-final iteration, ignore any tool_calls the model still
        # emits despite tool_choice="none" — some gateways/models keep the pattern
        # going anyway. Executing them here would run past the loop's last
        # pass with no synthesis call left, returning an empty final_text.
        if tool_calls_dict and not is_last_iteration:
            # Tool calls were found — execute the tools. Any content already
            # forwarded via on_content this iteration is being discarded from
            # final_text; let the caller undo stateful side effects from it.
            if content_chunks and on_discard:
                await on_discard()
            iterations_used += 1
            tool_names = [tc["name"] for tc in tool_calls_dict.values()]
            if on_tool_start:
                await on_tool_start(tool_names, iteration)

            messages.append({
                "role": "assistant",
                "content": "".join(content_chunks),
                "tool_calls": [
                    {"id": tc["id"], "type": "function",
                     "function": {"name": tc["name"], "arguments": tc["arguments"]}}
                    for tc in tool_calls_dict.values()
                ]
            })
            repeated_any = False
            for tc in tool_calls_dict.values():
                try:
                    args = json.loads(tc["arguments"])
                except Exception:
                    args = {}
                call_key = f"{tc['name']}::{json.dumps(args, sort_keys=True, default=str)}"
                if call_key in seen_tool_calls:
                    result = seen_tool_calls[call_key]
                    repeated_any = True
                else:
                    result = await tools.execute_tool(tc["name"], args, mcp_sessions=mcp_sessions, client=active_client, model=actual_model)
                    seen_tool_calls[call_key] = result
                messages.append({"role": "tool", "tool_call_id": tc["id"], "content": str(result)})

            if repeated_any:
                messages.append({
                    "role": "user",
                    "content": "[SYSTEM NOTICE] One or more tool calls above exactly repeated a call you already made — "
                                "the result shown is reused, not fresh. Don't repeat identical calls; either try a "
                                "meaningfully different query/tool, or answer now with what you've already gathered."
                })
            # Tools are only offered on iterations 1..max_iterations-1 (the last
            # iteration is always forced to tool_choice="none"). Warn one iteration
            # ahead of that cutoff, not one call late — telling the model it
            # has "one more opportunity" right as that opportunity is actually
            # being revoked just makes it try (and lose) a tool call it was
            # never going to get, instead of answering with what it has.
            remaining_tool_iterations = (max_iterations - 1) - iteration
            if remaining_tool_iterations == 1:
                messages.append({
                    "role": "user",
                    "content": "[SYSTEM NOTICE] You have one more opportunity to call a tool. After that you must "
                                "give your final answer using whatever information you've gathered so far."
                })
            elif remaining_tool_iterations == 0:
                messages.append({
                    "role": "user",
                    "content": "[SYSTEM NOTICE] Tool access ends now — your next turn will have no tools available, "
                                "and any tool call you attempt will be ignored. You must answer directly, right now, "
                                "using only what you've already gathered, even if it's incomplete."
                })

            if on_tool_done:
                await on_tool_done(iteration)
        else:
            # No tool calls (or this was the forced-final iteration) — content
            # was already streamed live via on_content.
            final_text = "".join(content_chunks)
            if not final_text and is_last_iteration and tool_calls_dict:
                # Model ignored the forced-answer instruction and tried to call
                # a tool anyway with no text content — guarantee a non-empty reply.
                logger.warning("ReAct loop: model emitted tool_calls on the forced-final iteration with no text; falling back to a generic answer.")
                final_text = ("I wasn't able to finish researching this within my tool-call budget, so I don't "
                               "have a confident final answer. Feel free to ask me to continue or narrow the question.")
                # This fallback is synthesized after the stream ends, so unlike
                # real content chunks it was never passed to on_content. WS/SSE
                # callers discard this function's return value and build what
                # they show the user solely from on_content calls, so without
                # this they'd still display nothing despite final_text being set.
                if on_content is not None:
                    await on_content(final_text)
            # Not appended to `messages` here: each caller saves its own (diagram-fenced)
            # final answer once, and appending here too stored the reply twice.
            break

    # Compute total accumulated tokens across all iterations
    total_prompt = sum(a.get("prompt_tokens", 0) for a in activity_log)
    total_completion = sum(a.get("completion_tokens", 0) for a in activity_log)

    return final_text, iterations_used, total_prompt, total_completion, activity_log

# ==========================================
# 1. WEBSOCKET ENDPOINT
# ==========================================
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    auth_header = websocket.headers.get("Authorization")
    # Browser WebSocket API cannot set custom headers; accept the full "Scheme token"
    # value via query param as a fallback (URL-encoded by the client).
    if not auth_header:
        auth_header = websocket.query_params.get("access_token")
    if not auth_header or " " not in auth_header:
        await websocket.send_json({"event": "error", "payload": "Missing Token"})
        await websocket.close(code=1008, reason="Missing Token")
        return

    scheme, _, token = auth_header.partition(" ")
    try:
        if scheme == "Basic":
            ws_claims = validate_basic_auth(token)
        elif scheme == "Bearer":
            ws_claims = validate_jwt(token)
        else:
            raise ValueError(f"Unsupported auth scheme: {scheme}")
    except Exception:
        await websocket.send_json({"event": "error", "payload": "Invalid Token"})
        await websocket.close(code=1008, reason="Invalid Token")
        return

    ws_verified_email = await resolve_verified_email(ws_claims, token if scheme == "Bearer" else None)

    await websocket.send_json({"event": "connected", "payload": {"status": "ready"}})

    try:
        while True:
            data = await websocket.receive_text()
            request = json.loads(data)
            payload = request.get("payload", {})
            user_text = payload.get("text")
            session_id = payload.get("session_id") or payload.get("previous_interaction_id") or str(uuid.uuid4())

            if not user_text: continue

            config = await get_live_config()

            ws_user_info = payload.get("user_info") or {}
            portkey_metadata = build_portkey_metadata(payload.get("task_type"), ws_user_info)

            redis_key = f"session:{session_id}"
            raw_history = await redis_client.get(redis_key)
            messages = json.loads(raw_history) if raw_history else [{"role": "system", "content": config["system_prompt"]}]
            if raw_history: messages[0] = {"role": "system", "content": config["system_prompt"]}
            
            messages.append({"role": "user", "content": user_text})
            if len(messages) > 21: messages = [messages[0]] + messages[-20:]

            actual_model = GATEWAY_MODEL
            active_client = get_llm_client(config)

            await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": "**⚙️ Agent Pipeline**\n\n* 🔍 **Phase 1:** Analyzing User Intent...\n"}})

            try:
                async with mcp_sessions_context(config, ws_verified_email, session_id) as (tool_schemas, mcp_sessions, mcp_failures):
                # --- PHASE 1: STREAMING ---
                    logging.info(f"🕵️ TOOL SCHEMAS BEING SENT: {tool_schemas}")
                    if mcp_failures:
                        failed_names = ", ".join(f["slug"] for f in mcp_failures)
                        await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": f"* ⚠️ MCP tool(s) unavailable this turn (connection issue): `{failed_names}` — continuing without them.\n"}})

                # 1. GENERATE THE TRACE ID HERE
                    current_trace_id = str(uuid.uuid4())

                    raw_stream = await active_client.chat.completions.with_raw_response.create(
                        model=actual_model,
                        messages=messages,
                        tools=tool_schemas if tool_schemas else None,
                        stream=True,
                        stream_options={"include_usage": True},
                        extra_headers={
                            "x-portkey-trace-id": current_trace_id,
                            "x-portkey-metadata": portkey_metadata
                        }
                    )
                    response = raw_stream.parse()

                    full_response = ""
                    tool_calls_dict = {}
                    tool_call_index_to_key = {}
                    is_using_tool = False
                    stream_model_used = ""
                    stream_usage = None
                    reasoning_started = False
                    diagram_fencer = DiagramFencer()

                    async for chunk in response:
                        if not chunk.choices:
                            if getattr(chunk, 'usage', None):
                                stream_usage = chunk.usage
                            continue
                        delta = chunk.choices[0].delta

                        if getattr(delta, 'reasoning_content', None):
                            prefix = "" if reasoning_started else "\n\n* 💭 **Model reasoning:**\n"
                            reasoning_started = True
                            await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": prefix + delta.reasoning_content}})

                        if getattr(delta, 'tool_calls', None):
                            is_using_tool = True
                            for tc in delta.tool_calls:
                                logger.info(f"🔬 RAW TOOL_CALL DELTA (ws): index={tc.index!r} id={getattr(tc, 'id', None)!r} function={getattr(tc, 'function', None)!r}")
                                accumulate_tool_call_delta(tc, tool_calls_dict, tool_call_index_to_key)

                        if getattr(delta, 'content', None):
                            fenced_chunk = diagram_fencer.feed(delta.content)
                            full_response += fenced_chunk
                            if fenced_chunk:
                                await websocket.send_json({"event": "agent_stream", "payload": {"chunk": fenced_chunk}})
                        if getattr(chunk, 'model', None):
                            stream_model_used = chunk.model
                        if getattr(chunk, 'usage', None):
                            stream_usage = chunk.usage

                    async def ws_on_discard():
                        nonlocal full_response
                        trailing = diagram_fencer.reset()
                        if trailing:
                            full_response += trailing
                            await websocket.send_json({"event": "agent_stream", "payload": {"chunk": trailing}})

                    if is_using_tool:
                        # Content streamed above (if any) was speculative prose
                        # before the model pivoted to a tool call — close off
                        # any dangling fence it left open before tool results
                        # and the loop's own content start arriving.
                        await ws_on_discard()
                        # Execute first iteration's tool calls
                        first_tool_names = [tc["name"] for tc in tool_calls_dict.values()]
                        await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": f"* 🛠️ **Iteration 1:** Executing `{', '.join(first_tool_names)}`...\n"}})
                        assistant_tool_calls = []
                        for tc in tool_calls_dict.values():
                            safe_args = tc["arguments"]
                            try: json.loads(safe_args)
                            except: safe_args = "{}"
                            assistant_tool_calls.append({
                                "id": tc["id"], "type": "function", "function": {"name": tc["name"], "arguments": safe_args}
                            })
                        messages.append({"role": "assistant", "content": "", "tool_calls": assistant_tool_calls})
                        for tc in tool_calls_dict.values():
                            try: args = json.loads(tc["arguments"])
                            except: args = {}
                            tool_result = await tools.execute_tool(tc["name"], args, mcp_sessions=mcp_sessions, client=active_client, model=actual_model)
                            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": str(tool_result)})

                        # --- AGENTIC RAG: ReAct loop for further iterations ---
                        async def ws_tool_start(t_names, iteration):
                            await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": f"* 🛠️ **Iteration {iteration + 1}:** Executing `{', '.join(t_names)}`...\n"}})
                        async def ws_tool_done(iteration):
                            await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": "* 🔄 Reasoning over retrieved data...\n"}})
                        async def ws_on_content(chunk):
                            nonlocal full_response
                            fenced_chunk = diagram_fencer.feed(chunk)
                            full_response += fenced_chunk
                            if fenced_chunk:
                                await websocket.send_json({"event": "agent_stream", "payload": {"chunk": fenced_chunk}})

                        _, extra_iters, loop_prompt_tok, loop_compl_tok, loop_activities = await run_react_loop(
                            active_client, actual_model, messages, tool_schemas,
                            current_trace_id, portkey_metadata,
                            on_tool_start=ws_tool_start,
                            on_tool_done=ws_tool_done,
                            on_content=ws_on_content,
                            on_discard=ws_on_discard,
                            mcp_sessions=mcp_sessions,
                        )
                        total_iters = 1 + extra_iters
                        await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": f"* ✅ Completed {total_iters} retrieval iteration(s).\n\n"}})
                        # Emit all LLM activities numbered
                        first_act = extract_portkey_activity(raw_stream, parsed_response=stream_usage, stream_model=stream_model_used, label="Initial")
                        all_activities = [first_act] + loop_activities
                        pk_info_final = format_portkey_activities(all_activities, trace_id=current_trace_id)
                        if pk_info_final:
                            await websocket.send_json({"event": "routing_info", "payload": {"info": pk_info_final}})
                    else:
                        if not full_response:
                            await websocket.send_json({"event": "agent_thinking", "payload": {"chunk": "* 🎯 **Phase 2:** Direct Resolution. No tools required.\n\n"}})
                        # Emit routing info for direct (no-tools) responses
                        act_direct = extract_portkey_activity(raw_stream, parsed_response=stream_usage, stream_model=stream_model_used, label="Response")
                        pk_info_direct = format_portkey_activities([act_direct], trace_id=current_trace_id)
                        if pk_info_direct:
                            await websocket.send_json({"event": "routing_info", "payload": {"info": pk_info_direct}})

                    trailing_fence = diagram_fencer.flush()
                    if trailing_fence:
                        full_response += trailing_fence
                        await websocket.send_json({"event": "agent_stream", "payload": {"chunk": trailing_fence}})

                    messages.append({"role": "assistant", "content": full_response})
                    await redis_client.setex(redis_key, SESSION_TTL, json.dumps(messages))

                    # 4. SEND THE TRACE ID TO THE UI
                    await websocket.send_json({"event": "trace_id", "payload": {"trace_id": current_trace_id}})

                    await websocket.send_json({"event": "agent_complete", "payload": {"id": session_id, "full_text": full_response}})

            except Exception as e:
                logger.error(f"WebSocket LLM Error [trace={current_trace_id}]: {e}")
                err_str = str(e)
                if "446" in err_str and "guardrail" in err_str.lower():
                    error_msg = "\n\n🚨 **Threat detected:** Your message was blocked by security guardrails."
                else:
                    error_msg = f"\n\n⚠️ **Agent Error:** {str(e)}"
                error_msg += f"\n\n_Trace ID: `{current_trace_id}`_"
                await websocket.send_json({"event": "agent_stream", "payload": {"chunk": error_msg}})
                await websocket.send_json({"event": "agent_complete", "payload": {"id": session_id, "full_text": error_msg}})

    except WebSocketDisconnect:
        logger.info("Bridge disconnected.")
    except Exception as e:
        logger.error(f"Error: {e}")


# ==========================================
# 2. STANDARD REST API 
# ==========================================
@app.post("/api/v1/chat")
async def rest_chat_endpoint(request: ChatRequest, token_payload: dict = Depends(verify_request_auth)):
    session_id = request.session_id or str(uuid.uuid4())
    
    config = await get_live_config()
    thinking_content = "**⚙️ Agent Pipeline**\n\n* 🔍 **Phase 1:** Analyzing User Intent...\n"

    redis_key = f"session:{session_id}"
    raw_history = await redis_client.get(redis_key)
    messages = json.loads(raw_history) if raw_history else [{"role": "system", "content": config["system_prompt"]}]
    if raw_history: messages[0] = {"role": "system", "content": config["system_prompt"]}
    messages.append({"role": "user", "content": request.text})

    actual_model = GATEWAY_MODEL

    active_client = get_llm_client(config)
    portkey_routing_info = ""
    portkey_metadata = build_portkey_metadata(request.task_type, request.user_info)

    try:
        async with mcp_sessions_context(config, token_payload.get("verified_email"), session_id) as (tool_schemas, mcp_sessions, mcp_failures):
            if mcp_failures:
                failed_names = ", ".join(f["slug"] for f in mcp_failures)
                thinking_content += f"* ⚠️ MCP tool(s) unavailable this turn (connection issue): `{failed_names}` — continuing without them.\n"

            # --- NEW: Generate Trace ID ---
            current_trace_id = str(uuid.uuid4())

            raw_response = await active_client.chat.completions.with_raw_response.create(
                model=actual_model, messages=messages, tools=tool_schemas if tool_schemas else None, stream=False,
                extra_headers={
                    "x-portkey-trace-id": current_trace_id,
                    "x-portkey-metadata": portkey_metadata,
                }
            )

            response = raw_response.parse()
            response_message = response.choices[0].message
            final_text = response_message.content or ""

            pk_info = extract_portkey_routing_info(raw_response, response, trace_id=current_trace_id)
            if pk_info:
                portkey_routing_info = pk_info

            if response_message.tool_calls:
                tool_names = [tc.function.name for tc in response_message.tool_calls]
                thinking_content += f"* 🛠️ **Iteration 1:** Executing `{', '.join(tool_names)}`...\n"
                messages.append({
                    "role": "assistant",
                    "content": response_message.content or "",
                    "tool_calls": [
                        {"id": tc.id, "type": "function",
                         "function": {"name": tc.function.name, "arguments": tc.function.arguments}}
                        for tc in response_message.tool_calls
                    ]
                })
                for tool_call in response_message.tool_calls:
                    try: args = json.loads(tool_call.function.arguments)
                    except: args = {}
                    tool_result = await tools.execute_tool(tool_call.function.name, args, mcp_sessions=mcp_sessions, client=active_client, model=actual_model)
                    messages.append({"role": "tool", "tool_call_id": tool_call.id, "content": str(tool_result)})

                # --- AGENTIC RAG: ReAct loop for further iterations ---
                async def rest_tool_start(t_names, iteration):
                    nonlocal thinking_content
                    thinking_content += f"* 🛠️ **Iteration {iteration + 1}:** Executing `{', '.join(t_names)}`...\n"
                async def rest_tool_done(iteration):
                    nonlocal thinking_content
                    thinking_content += "* 🔄 Reasoning over retrieved data...\n"

                final_text, extra_iters, loop_pt, loop_ct, loop_acts_rest = await run_react_loop(
                    active_client, actual_model, messages, tool_schemas,
                    current_trace_id, portkey_metadata,
                    on_tool_start=rest_tool_start,
                    on_tool_done=rest_tool_done,
                    mcp_sessions=mcp_sessions,
                )
                total_iters = 1 + extra_iters
                thinking_content += f"* ✅ Completed {total_iters} retrieval iteration(s).\n\n"
                # final_text is the model's tool-grounded answer; don't re-query for a
                # fresh one (a re-sample loses that grounding).
                first_act_rest = extract_portkey_activity(raw_response, response, label="Initial")
                all_acts_rest = [first_act_rest] + loop_acts_rest
                pk_info = format_portkey_activities(all_acts_rest, trace_id=current_trace_id)
                if pk_info:
                    portkey_routing_info = pk_info
            else:
                thinking_content += "* 🎯 **Phase 2:** Direct Resolution. No tools required.\n\n"

            final_text = fence_diagram_blocks(final_text)
            messages.append({"role": "assistant", "content": final_text})
            await redis_client.setex(redis_key, SESSION_TTL, json.dumps(messages))

            return {"session_id": session_id, "response": final_text, "thinking": thinking_content, "status": "success", "trace_id": current_trace_id, "routing_info": portkey_routing_info}

    except Exception as e:
        logger.error(f"REST LLM Error [trace={current_trace_id}]: {e}")
        err_str = str(e)
        if "446" in err_str and "guardrail" in err_str.lower():
            clean_error = "🚨 **Threat detected:** Your message was blocked by security guardrails."
        else:
            clean_error = f"⚠️ Agent Error: {err_str}"
        clean_error += f"\n\n_Trace ID: `{current_trace_id}`_"
        return {"session_id": session_id, "response": clean_error, "thinking": thinking_content, "status": "error", "trace_id": current_trace_id}


# ==========================================
# 3. STREAMING REST API
# ==========================================
@app.post("/api/v1/chat/stream")
async def stream_chat_endpoint(request: ChatRequest, token_payload: dict = Depends(verify_request_auth)):
    session_id = request.session_id or str(uuid.uuid4())
    
    config = await get_live_config()

    portkey_metadata = build_portkey_metadata(request.task_type, request.user_info)

    async def event_generator():
        start_pipe = json.dumps({'type': 'thinking', 'chunk': '**⚙️ Agent Pipeline**\n\n* 🔍 **Phase 1:** Analyzing User Intent...\n'})
        yield f"data: {start_pipe}\n\n"

        redis_key = f"session:{session_id}"
        raw_history = await redis_client.get(redis_key)
        messages = json.loads(raw_history) if raw_history else [{"role": "system", "content": config["system_prompt"]}]
        if raw_history: messages[0] = {"role": "system", "content": config["system_prompt"]}
        messages.append({"role": "user", "content": request.text})

        actual_model = GATEWAY_MODEL

        active_client = get_llm_client(config)

        try:
            async with mcp_sessions_context(config, token_payload.get("verified_email"), session_id) as (tool_schemas, mcp_sessions, mcp_failures):
                if mcp_failures:
                    failed_names = ", ".join(f["slug"] for f in mcp_failures)
                    warn_msg = json.dumps({'type': 'thinking', 'chunk': f'* ⚠️ MCP tool(s) unavailable this turn (connection issue): `{failed_names}` — continuing without them.\n'})
                    yield f"data: {warn_msg}\n\n"

                # --- NEW: Generate Trace ID ---
                current_trace_id = str(uuid.uuid4())

                # --- PHASE 1: STREAMING ---
                raw_stream_sse = await active_client.chat.completions.with_raw_response.create(
                    model=actual_model, messages=messages, tools=tool_schemas if tool_schemas else None, stream=True,
                    stream_options={"include_usage": True},
                    extra_headers={
                        "x-portkey-trace-id": current_trace_id,
                        "x-portkey-metadata": portkey_metadata
                    }
                )
                response = raw_stream_sse.parse()

                full_response = ""
                tool_calls_dict = {}
                tool_call_index_to_key = {}
                is_using_tool = False
                sse_stream_model = ""
                sse_stream_usage = None
                reasoning_started = False
                diagram_fencer = DiagramFencer()

                async for chunk in response:
                    if not chunk.choices:
                        if getattr(chunk, 'usage', None):
                            sse_stream_usage = chunk.usage
                        continue
                    delta = chunk.choices[0].delta

                    if getattr(delta, 'reasoning_content', None):
                        prefix = "" if reasoning_started else "\n\n* 💭 **Model reasoning:**\n"
                        reasoning_started = True
                        safe_chunk = json.dumps({'type': 'thinking', 'chunk': prefix + delta.reasoning_content})
                        yield f"data: {safe_chunk}\n\n"

                    if getattr(delta, 'tool_calls', None):
                        is_using_tool = True
                        for tc in delta.tool_calls:
                            logger.info(f"🔬 RAW TOOL_CALL DELTA (sse): index={tc.index!r} id={getattr(tc, 'id', None)!r} function={getattr(tc, 'function', None)!r}")
                            accumulate_tool_call_delta(tc, tool_calls_dict, tool_call_index_to_key)

                    if getattr(delta, 'content', None):
                        fenced_chunk = diagram_fencer.feed(delta.content)
                        full_response += fenced_chunk
                        if fenced_chunk:
                            safe_chunk = json.dumps({'type': 'content', 'chunk': fenced_chunk})
                            yield f"data: {safe_chunk}\n\n"
                    if getattr(chunk, 'model', None):
                        sse_stream_model = chunk.model
                    if getattr(chunk, 'usage', None):
                        sse_stream_usage = chunk.usage

                if is_using_tool:
                    # Content streamed above (if any) was speculative prose
                    # before the model pivoted to a tool call — close off any
                    # dangling fence it left open before the tool loop's own
                    # content starts arriving.
                    trailing_before_tools = diagram_fencer.reset()
                    if trailing_before_tools:
                        full_response += trailing_before_tools
                        yield "data: " + json.dumps({'type': 'content', 'chunk': trailing_before_tools}) + "\n\n"
                    first_tool_names = [tc["name"] for tc in tool_calls_dict.values()]
                    yield f"data: {json.dumps({'type': 'thinking', 'chunk': f'* 🛠️ **Iteration 1:** Executing `{chr(96)}{chr(44).join(first_tool_names)}{chr(96)}`...{chr(10)}'})}\n\n"
                    assistant_tool_calls = []
                    for tc in tool_calls_dict.values():
                        safe_args = tc["arguments"]
                        try: json.loads(safe_args)
                        except: safe_args = "{}"
                        assistant_tool_calls.append({"id": tc["id"], "type": "function", "function": {"name": tc["name"], "arguments": safe_args}})
                    messages.append({"role": "assistant", "content": "", "tool_calls": assistant_tool_calls})
                    for tc in tool_calls_dict.values():
                        try: args = json.loads(tc["arguments"])
                        except: args = {}
                        tool_result = await tools.execute_tool(tc["name"], args, mcp_sessions=mcp_sessions, client=active_client, model=actual_model)
                        messages.append({"role": "tool", "tool_call_id": tc["id"], "content": str(tool_result)})

                    # --- AGENTIC RAG: buffer further iterations then stream final ---
                    sse_extra_thinking = []
                    sse_content_chunks = []
                    async def sse_tool_start(t_names, iteration):
                        sse_extra_thinking.append(f"* 🛠️ **Iteration {iteration + 1}:** Executing `{', '.join(t_names)}`...\n")
                    async def sse_tool_done(iteration):
                        sse_extra_thinking.append("* 🔄 Reasoning over retrieved data...\n")
                    async def sse_on_content(chunk):
                        sse_content_chunks.append(chunk)
                    async def sse_on_discard():
                        # Nothing in sse_content_chunks has been fed through
                        # diagram_fencer or sent to the client yet (that only
                        # happens once, after the whole loop finishes) — so a
                        # discarded iteration's speculative content can simply
                        # be dropped, with no fencer state to undo.
                        sse_content_chunks.clear()

                    _, extra_iters, sse_loop_pt, sse_loop_ct, sse_loop_acts = await run_react_loop(
                        active_client, actual_model, messages, tool_schemas,
                        current_trace_id, portkey_metadata,
                        on_tool_start=sse_tool_start,
                        on_tool_done=sse_tool_done,
                        on_content=sse_on_content,
                        on_discard=sse_on_discard,
                        mcp_sessions=mcp_sessions,
                    )
                    for t in sse_extra_thinking:
                        yield f"data: {json.dumps({'type': 'thinking', 'chunk': t})}\n\n"
                    total_iters = 1 + extra_iters
                    yield f"data: {json.dumps({'type': 'thinking', 'chunk': f'* ✅ Completed {total_iters} retrieval iteration(s).{chr(10)}{chr(10)}'})}\n\n"

                    # Emit content chunks collected during run_react_loop streaming
                    for chunk in sse_content_chunks:
                        fenced_chunk = diagram_fencer.feed(chunk)
                        full_response += fenced_chunk
                        if fenced_chunk:
                            yield "data: " + json.dumps({'type': 'content', 'chunk': fenced_chunk}) + "\n\n"
                else:
                    if not full_response:
                        direct_msg = json.dumps({'type': 'thinking', 'chunk': "* 🎯 **Phase 2:** Direct Resolution. No tools required.\n\n"})
                        yield f"data: {direct_msg}\n\n"

                trailing_fence = diagram_fencer.flush()
                if trailing_fence:
                    full_response += trailing_fence
                    yield "data: " + json.dumps({'type': 'content', 'chunk': trailing_fence}) + "\n\n"

                messages.append({"role": "assistant", "content": full_response})
                await redis_client.setex(redis_key, SESSION_TTL, json.dumps(messages))
                trace_msg = json.dumps({'type': 'trace_id', 'chunk': current_trace_id})
                yield f"data: {trace_msg}\n\n"
                session_msg = json.dumps({'type': 'session_id', 'chunk': session_id})
                yield f"data: {session_msg}\n\n"
                first_act_sse = extract_portkey_activity(raw_stream_sse, parsed_response=sse_stream_usage, stream_model=sse_stream_model, label="Initial")
                all_acts_sse = [first_act_sse] + (locals().get('sse_loop_acts', []) if is_using_tool else [])
                pk_info_sse = format_portkey_activities(all_acts_sse, trace_id=current_trace_id)
                if pk_info_sse:
                    yield "data: " + json.dumps({'type': 'routing_info', 'info': pk_info_sse}) + "\n\n"
                yield "data: [DONE]\n\n"

        except Exception as e:
            logger.error(f"Stream LLM Error [trace={current_trace_id}]: {e}")
            err_str = str(e)
            if "446" in err_str and "guardrail" in err_str.lower():
                err_text = "\n\n🚨 **Threat detected:** Your message was blocked by security guardrails."
            else:
                err_text = f"\n\n⚠️ **Agent Error:** {err_str}"
            err_text += f"\n\n_Trace ID: `{current_trace_id}`_"
            safe_err = json.dumps({'type': 'content', 'chunk': err_text})
            yield f"data: {safe_err}\n\n"
            yield "data: [DONE]\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")

# ==========================================
# 4. UNAUTHENTICATED STANDARD REST API (BLOCKING)
# ==========================================
@app.post("/api/v1/chat/public")
async def public_rest_chat_endpoint(request: ChatRequest):
    """
    Open REST API endpoint WITHOUT CyberArk Identity (Idira) OAuth 2.0.
    Standard blocking request (non-streaming).
    Supports Tools and dynamic system instructions.
    """
    logger.info(f"Received UNAUTHENTICATED public blocking chat request: {request.text}")

    session_id = request.session_id or str(uuid.uuid4())

    config = await get_live_config()
    thinking_content = ""

    portkey_metadata = build_portkey_metadata(request.task_type, request.user_info)

    thinking_content += "**⚙️ Agent Pipeline**\n\n* 🔍 **Phase 1:** Analyzing User Intent...\n"

    redis_key = f"session:{session_id}"
    raw_history = await redis_client.get(redis_key)
    messages = json.loads(raw_history) if raw_history else [{"role": "system", "content": config["system_prompt"]}]
    if raw_history: messages[0] = {"role": "system", "content": config["system_prompt"]}
    messages.append({"role": "user", "content": request.text})

    actual_model = GATEWAY_MODEL

    active_client = get_llm_client(config)
    portkey_routing_info = ""

    try:
        # Unauthenticated endpoint: no sub-agents (a db-agent may expose internal data).
        async with mcp_sessions_context({**config, "a2a_agents": []}, None, session_id) as (tool_schemas, mcp_sessions, mcp_failures):
            if mcp_failures:
                failed_names = ", ".join(f["slug"] for f in mcp_failures)
                thinking_content += f"* ⚠️ MCP tool(s) unavailable this turn (connection issue): `{failed_names}` — continuing without them.\n"

            # --- NEW: Generate Trace ID ---
            current_trace_id = str(uuid.uuid4())

            raw_pub = await active_client.chat.completions.with_raw_response.create(
                model=actual_model, messages=messages, tools=tool_schemas if tool_schemas else None, stream=False,
                extra_headers={
                    "x-portkey-trace-id": current_trace_id,
                    "x-portkey-metadata": portkey_metadata,
                }
            )
            response = raw_pub.parse()
            response_message = response.choices[0].message
            final_text = response_message.content or ""

            pk_info_pub = extract_portkey_routing_info(raw_pub, response, trace_id=current_trace_id)
            if pk_info_pub:
                portkey_routing_info = pk_info_pub

            if response_message.tool_calls:
                tool_names = [tc.function.name for tc in response_message.tool_calls]
                thinking_content += f"* 🛠️ **Iteration 1:** Executing `{', '.join(tool_names)}`...\n"
                messages.append({
                    "role": "assistant",
                    "content": response_message.content or "",
                    "tool_calls": [
                        {"id": tc.id, "type": "function",
                         "function": {"name": tc.function.name, "arguments": tc.function.arguments}}
                        for tc in response_message.tool_calls
                    ]
                })
                for tool_call in response_message.tool_calls:
                    try: args = json.loads(tool_call.function.arguments)
                    except: args = {}
                    tool_result = await tools.execute_tool(tool_call.function.name, args, mcp_sessions=mcp_sessions, client=active_client, model=actual_model)
                    messages.append({"role": "tool", "tool_call_id": tool_call.id, "content": str(tool_result)})

                # --- AGENTIC RAG: ReAct loop for further iterations ---
                async def pub_tool_start(t_names, iteration):
                    nonlocal thinking_content
                    thinking_content += f"* 🛠️ **Iteration {iteration + 1}:** Executing `{', '.join(t_names)}`...\n"
                async def pub_tool_done(iteration):
                    nonlocal thinking_content
                    thinking_content += "* 🔄 Reasoning over retrieved data...\n"

                final_text, extra_iters, _, _, _ = await run_react_loop(
                    active_client, actual_model, messages, tool_schemas,
                    current_trace_id, portkey_metadata,
                    on_tool_start=pub_tool_start,
                    on_tool_done=pub_tool_done,
                    mcp_sessions=mcp_sessions,
                )
                total_iters = 1 + extra_iters
                thinking_content += f"* ✅ Completed {total_iters} retrieval iteration(s).\n\n"
            else:
                thinking_content += "* 🎯 **Phase 2:** Direct Resolution. No tools required.\n\n"

            final_text = fence_diagram_blocks(final_text)
            messages.append({"role": "assistant", "content": final_text})
            await redis_client.setex(redis_key, SESSION_TTL, json.dumps(messages))

            return {"session_id": session_id, "response": final_text, "thinking": thinking_content, "status": "success", "trace_id": current_trace_id, "routing_info": portkey_routing_info}

    except Exception as e:
        logger.error(f"REST LLM Error [trace={current_trace_id}]: {e}")
        err_str = str(e)
        if "446" in err_str and "guardrail" in err_str.lower():
            clean_error = "🚨 **Threat detected:** Your message was blocked by security guardrails."
        else:
            clean_error = f"⚠️ Agent Error: {err_str}"
        clean_error += f"\n\n_Trace ID: `{current_trace_id}`_"
        return {"session_id": session_id, "response": clean_error, "thinking": thinking_content, "status": "error", "trace_id": current_trace_id}
