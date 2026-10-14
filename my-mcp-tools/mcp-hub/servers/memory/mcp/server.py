"""Stateless MCP server exposing per-user agent memory backed by the self-hosted mem0 REST API."""

import os
import re
import uuid
from typing import Annotated, Any

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from pydantic import Field

API_URL = os.environ.get("MEM0_API_URL", "http://memory-api:8000").rstrip("/")
API_KEY = os.environ["ADMIN_API_KEY"]

EMAIL_RE = re.compile(r"^[a-z0-9._%+'-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$")

UserId = Annotated[str, Field(description="The current user's email address, exactly as given in the system prompt.")]

mcp = FastMCP(
    "agent-memory",
    instructions=(
        "Long-term memory per user. Search it at the start of a task for relevant preferences and facts. "
        "Save lasting preferences, facts about the user, and decisions. Never save passwords, keys, tokens "
        "or other secrets. Always use the current user's email from the system prompt as user_id."
    ),
    host="0.0.0.0",
    port=8000,
    stateless_http=True,
    json_response=True,
)

client = httpx.AsyncClient(base_url=API_URL, headers={"X-API-Key": API_KEY}, timeout=120)


def _user(user_id: str) -> str:
    uid = user_id.strip().lower()
    if len(uid) > 254 or not EMAIL_RE.match(uid):
        raise ToolError("user_id must be the current user's email address.")
    return uid


async def _call(method: str, path: str, **kwargs: Any) -> Any:
    try:
        resp = await client.request(method, path, **kwargs)
    except httpx.HTTPError:
        raise ToolError("Memory service is unavailable. Try again later.")
    if resp.status_code >= 500:
        raise ToolError(f"Memory service error (HTTP {resp.status_code}).")
    if resp.status_code >= 400:
        detail = ""
        try:
            detail = str(resp.json().get("detail", ""))[:200]
        except ValueError:
            pass
        raise ToolError(f"Memory request rejected (HTTP {resp.status_code}). {detail}".strip())
    return resp.json()


@mcp.tool()
async def memory_search(
    user_id: UserId,
    query: Annotated[str, Field(description="What to look for, e.g. 'preferred answer format'.")],
    limit: Annotated[int, Field(ge=1, le=20)] = 5,
) -> list[dict[str, Any]]:
    """Search this user's long-term memories for facts relevant to the query."""
    data = await _call("POST", "/search", json={"query": query, "filters": {"user_id": _user(user_id)}, "top_k": limit})
    return [
        {"id": m.get("id"), "memory": m.get("memory"), "score": m.get("score"), "updated_at": m.get("updated_at") or m.get("created_at")}
        for m in data.get("results", [])
    ]


@mcp.tool()
async def memory_add(
    user_id: UserId,
    content: Annotated[str, Field(description="A lasting fact, preference or decision, in plain sentences.", max_length=8000)],
) -> list[dict[str, Any]]:
    """Save lasting facts, preferences or decisions about this user. Existing memories are updated or replaced
    automatically when the new information contradicts them. Never include secrets or credentials."""
    data = await _call(
        "POST", "/memories", json={"messages": [{"role": "user", "content": content}], "user_id": _user(user_id)}
    )
    return [{"id": m.get("id"), "memory": m.get("memory"), "event": m.get("event")} for m in data.get("results", [])]


@mcp.tool()
async def memory_list(
    user_id: UserId,
    limit: Annotated[int, Field(ge=1, le=200)] = 50,
) -> list[dict[str, Any]]:
    """List this user's stored memories (most useful when the user asks what you remember about them)."""
    data = await _call("GET", "/memories", params={"user_id": _user(user_id), "top_k": limit})
    return [
        {"id": m.get("id"), "memory": m.get("memory"), "updated_at": m.get("updated_at") or m.get("created_at")}
        for m in data.get("results", [])
    ]


@mcp.tool()
async def memory_delete(
    user_id: UserId,
    memory_id: Annotated[str, Field(description="The id of a memory returned by memory_search or memory_list.")],
) -> str:
    """Delete one of this user's memories, e.g. when the user asks you to forget something."""
    uid = _user(user_id)
    try:
        mid = str(uuid.UUID(memory_id))
    except ValueError:
        raise ToolError("memory_id is not a valid memory id.")
    memory = await _call("GET", f"/memories/{mid}")
    if not memory or memory.get("user_id") != uid:
        raise ToolError("No such memory for this user.")
    await _call("DELETE", f"/memories/{mid}")
    return "Memory deleted."


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
