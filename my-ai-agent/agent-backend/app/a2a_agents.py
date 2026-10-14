"""A2A (Agent2Agent) sub-agents registered in the AI Gateway, exposed to the main
agent as one tool each (`a2a__{slug}`).

The a2a-sdk reads each agent card's protocol version and picks the matching
transport (A2A v1.0 `SendMessage` or v0.3 `message/send`), so this module never
deals with wire formats directly. Through the AI Gateway it prefers v0.3 when an
agent offers both (see _get_card).
"""
import asyncio
import copy
import json
import logging
import time
from contextlib import AsyncExitStack
from urllib.parse import urlparse

import httpx
from a2a.client import A2ACardResolver, ClientConfig, create_client
from a2a.client.card_resolver import parse_agent_card
from a2a.helpers.proto_helpers import get_artifact_text, get_message_text, new_text_message
from a2a.types import AgentCard, GetTaskRequest, Role, SendMessageRequest, Task, TaskState

logger = logging.getLogger(__name__)

CARD_CACHE_TTL_SECONDS = 300
TASK_POLL_INTERVAL_SECONDS = 2
TASK_POLL_TIMEOUT_SECONDS = 300
TOOL_DESCRIPTION_LIMIT = 1000

_PENDING = {TaskState.TASK_STATE_SUBMITTED, TaskState.TASK_STATE_WORKING}
_NEEDS_INPUT = {TaskState.TASK_STATE_INPUT_REQUIRED, TaskState.TASK_STATE_AUTH_REQUIRED}
_UNSUCCESSFUL = {TaskState.TASK_STATE_FAILED, TaskState.TASK_STATE_REJECTED, TaskState.TASK_STATE_CANCELED}

# (gateway URL, card URL) -> (fetched_at, card); avoids re-fetching every card on every message
_card_cache: dict[tuple[str, str | None], tuple[float, AgentCard]] = {}


async def _get_card(gateway_http: httpx.AsyncClient, base_url: str, card_url: str | None) -> AgentCard:
    cache_key = (base_url, card_url)
    cached = _card_cache.get(cache_key)
    if cached and time.monotonic() - cached[0] < CARD_CACHE_TTL_SECONDS:
        return cached[1]
    if card_url:
        # Card URL override. The gateway does card discovery in its cloud control plane and
        # only serves a stub card ({"url": ...}) at the agent URL, so the override points at the
        # agent's own card. Sent without the gateway key: it must never go to a non-gateway host.
        async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as plain_http:
            resp = await plain_http.get(card_url)
            resp.raise_for_status()
            card = parse_agent_card(resp.json())
    else:
        card = await A2ACardResolver(gateway_http, base_url).get_agent_card()
    # Calls must go through the AI Gateway. If the card advertises an endpoint on a
    # different host (the upstream agent itself), point it back at the gateway URL.
    gateway_host = urlparse(base_url).netloc
    for interface in card.supported_interfaces:
        if urlparse(interface.url).netloc != gateway_host:
            interface.url = base_url
    # The gateway doesn't forward the A2A-Version header, and A2A servers read a missing
    # header as 0.3, so a v1.0 request gets rejected ("A2A version '0.3' is not supported
    # by this handler"). Use the agent's v0.3 interface when it offers one.
    legacy = [copy.deepcopy(i) for i in card.supported_interfaces if i.protocol_version.startswith("0.")]
    if legacy and len(legacy) < len(card.supported_interfaces):
        del card.supported_interfaces[:]
        card.supported_interfaces.extend(legacy)
    _card_cache[cache_key] = (time.monotonic(), card)
    return card


def _describe(card: AgentCard) -> str:
    parts = [f"Delegate a request to the sub-agent '{card.name}'."]
    if card.description:
        parts.append(card.description.strip())
    skills = "; ".join(f"{s.name}: {s.description.rstrip('.')}".strip(": ") for s in card.skills)
    if skills:
        parts.append(f"Skills: {skills}.")
    parts.append("It can't see this conversation, but remembers earlier requests you sent it in this chat.")
    return " ".join(parts)[:TOOL_DESCRIPTION_LIMIT]


async def load_a2a_tools(
    agents: list[dict], gateway_api_key: str, redis_client, session_id: str | None, context_ttl: int
) -> tuple[list, dict, list]:
    """Resolve each enabled sub-agent and build its tool schema.

    Returns (schemas, entries, failures). Entries are keyed "a2a:{slug}" so they can sit in
    the same dict as MCP sessions; each holds an AsyncExitStack the caller must aclose().
    """
    schemas, entries, failures = [], {}, []

    async def _load(agent: dict):
        slug, base_url = agent["slug"], agent["url"].rstrip("/")
        stack = AsyncExitStack()
        try:
            http = await stack.enter_async_context(
                httpx.AsyncClient(
                    headers={"x-portkey-api-key": gateway_api_key},
                    timeout=httpx.Timeout(30.0, read=300.0),
                )
            )
            card = await _get_card(http, base_url, agent.get("card_url") or None)
            client = await create_client(card, client_config=ClientConfig(streaming=False, httpx_client=http))
            entries[f"a2a:{slug}"] = {
                "stack": stack,
                "client": client,
                "slug": slug,
                "session_id": session_id,
                "redis": redis_client,
                "context_ttl": context_ttl,
            }
            schemas.append({
                "type": "function",
                "function": {
                    "name": f"a2a__{slug}",
                    "description": _describe(card),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "message": {
                                "type": "string",
                                "description": "The full request for the sub-agent. It can't see this "
                                               "conversation, so include every detail it needs.",
                            }
                        },
                        "required": ["message"],
                    },
                },
            })
            logger.info(f"🤝 A2A sub-agent {slug}: '{card.name}' loaded")
        except Exception as e:
            await stack.aclose()
            logger.warning(f"A2A sub-agent '{slug}' unavailable: {e}")
            failures.append({"slug": f"{slug} (sub-agent)", "error": str(e)})

    await asyncio.gather(*[_load(a) for a in agents if a.get("slug") and a.get("url")], return_exceptions=True)
    return schemas, entries, failures


def _task_text(task: Task) -> str:
    text = "\n".join(t for t in (get_artifact_text(a) for a in task.artifacts) if t)
    if not text and task.status.HasField("message"):
        text = get_message_text(task.status.message)
    return text


async def _load_context(redis_client, key: str | None) -> dict:
    if not key:
        return {}
    try:
        raw = await redis_client.get(key)
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


async def _save_context(redis_client, key: str | None, ttl: int, context_id: str, task_id: str | None):
    if not key or not context_id:
        return
    try:
        await redis_client.setex(key, ttl, json.dumps({"context_id": context_id, "task_id": task_id}))
    except Exception as e:
        logger.warning(f"Could not save A2A context {key}: {e}")


async def execute_a2a_tool(namespaced_name: str, arguments: dict, sessions: dict) -> str:
    """Send the main agent's request to a sub-agent and return its reply as text. Never raises."""
    slug = namespaced_name.split("__", 1)[1]
    entry = sessions.get(f"a2a:{slug}")
    if not entry:
        return f"Error: sub-agent '{slug}' isn't available this turn."
    text = str((arguments or {}).get("message") or "").strip()
    if not text:
        return "Error: no message was given for the sub-agent."

    # One sub-agent conversation per chat session; a task waiting for input is continued.
    ctx_key = f"a2a_ctx:{entry['session_id']}:{slug}" if entry["session_id"] else None
    saved = await _load_context(entry["redis"], ctx_key)
    message = new_text_message(
        text,
        role=Role.ROLE_USER,
        context_id=saved.get("context_id") or None,
        task_id=saved.get("task_id") or None,
    )
    client = entry["client"]

    try:
        response = None
        async for response in client.send_message(SendMessageRequest(message=message)):
            pass
        if response is None:
            return f"Error: sub-agent '{slug}' returned no response."

        if response.HasField("message"):
            reply = response.message
            await _save_context(entry["redis"], ctx_key, entry["context_ttl"], reply.context_id, None)
            return get_message_text(reply) or "(the sub-agent returned an empty reply)"

        task = response.task
        deadline = time.monotonic() + TASK_POLL_TIMEOUT_SECONDS
        while task.status.state in _PENDING and time.monotonic() < deadline:
            await asyncio.sleep(TASK_POLL_INTERVAL_SECONDS)
            task = await client.get_task(GetTaskRequest(id=task.id))

        state = task.status.state
        await _save_context(
            entry["redis"], ctx_key, entry["context_ttl"], task.context_id,
            task.id if state in _NEEDS_INPUT else None,
        )
        reply_text = _task_text(task)
        if state in _NEEDS_INPUT:
            return f"The sub-agent needs more information: {reply_text or '(no details given)'}"
        if state in _UNSUCCESSFUL:
            return f"Sub-agent '{slug}' {TaskState.Name(state).removeprefix('TASK_STATE_').lower()}: {reply_text or 'no details given'}"
        if state in _PENDING:
            return f"Sub-agent '{slug}' is still working after {TASK_POLL_TIMEOUT_SECONDS}s; try again later."
        return reply_text or "(the sub-agent finished without a text reply)"
    except Exception as e:
        return f"Sub-agent '{slug}' error: {e}"
