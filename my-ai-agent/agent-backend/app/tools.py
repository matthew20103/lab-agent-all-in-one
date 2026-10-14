import logging
import asyncio
import httpx
from contextlib import AsyncExitStack
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

import a2a_agents

logger = logging.getLogger(__name__)


# -----------------------------------------
# AI GATEWAY MCP HELPERS
# Each configured slug is an MCP server hosted behind the AI Gateway's MCP
# port (a separate host:port from the chat-completions gateway), at
# {mcp_gateway_url}/{slug}/mcp.
# -----------------------------------------

# Per-user MCP servers. Their `user_id` argument is never exposed to the model:
# it's hidden from the schema and filled in from the verified login email in
# execute_mcp_tool, so a prompt injection can't point a call at another user.
USER_SCOPED_MCP_SLUGS = {"agent-memory"}

USER_SCOPED_TOOL_NOTE = " The current user's identity is supplied automatically; never ask the user for it."


def _without_user_id(input_schema: dict | None) -> dict:
    schema = dict(input_schema or {"type": "object"})
    schema["properties"] = {k: v for k, v in (schema.get("properties") or {}).items() if k != "user_id"}
    if "required" in schema:
        schema["required"] = [r for r in schema["required"] if r != "user_id"]
    return schema


async def get_mcp_tool_schemas(slugs: list[str], mcp_gateway_url: str, gateway_api_key: str, user_email: str | None = None, max_attempts: int = 2) -> tuple[list, dict, list]:
    """
    For each AI Gateway MCP server slug, open a session, list tools, and convert
    to OpenAI function-calling schema format. Retries a slug up to `max_attempts`
    times (short backoff between tries) since MCP gateway connections can fail
    transiently — e.g. "SSE stream ended without a response" on a cold upstream.

    User-scoped slugs are skipped entirely when `user_email` is None (no verified
    identity, e.g. Basic Auth or the public endpoint).

    Returns:
        schemas      — list of OpenAI-compatible tool dicts
        sessions     — {slug: {"session": ClientSession, "stack": AsyncExitStack,
                       "user_email": str | None}}
                       Caller must call stack.aclose() for each entry when done.
        failed_slugs — [{"slug": str, "error": str}] for slugs still unavailable
                       after all retry attempts
    """
    schemas = []
    sessions = {}
    failed_slugs = []
    base = mcp_gateway_url.rstrip("/")

    async def _connect_slug(slug: str):
        url = f"{base}/{slug}/mcp"
        user_scoped = slug in USER_SCOPED_MCP_SLUGS
        headers = {"x-portkey-api-key": gateway_api_key}
        if user_scoped:
            # Not relied on yet (the wrapper reads user_id); only useful if the
            # AI Gateway forwards it and the wrapper switches to header identity.
            headers["X-User-Email"] = user_email
        last_error = None
        for attempt in range(1, max_attempts + 1):
            stack = AsyncExitStack()
            try:
                # httpx's 5 s default read timeout kills slow tool calls (search, retrieval) and the
                # MCP SDK reports it only as "SSE stream ended without a response"; match the SDK defaults.
                http_client = await stack.enter_async_context(
                    httpx.AsyncClient(headers=headers, timeout=httpx.Timeout(30.0, read=300.0))
                )
                read, write = await stack.enter_async_context(
                    streamable_http_client(url, http_client=http_client)
                )
                session = await stack.enter_async_context(ClientSession(read, write))
                await session.initialize()
                tools_response = await session.list_tools()
                sessions[slug] = {"session": session, "stack": stack, "user_email": user_email if user_scoped else None}
                for t in tools_response.tools:
                    input_schema = getattr(t, "inputSchema", None) or getattr(t, "input_schema", None)
                    description = t.description or ""
                    if user_scoped:
                        parameters = _without_user_id(input_schema)
                        description += USER_SCOPED_TOOL_NOTE
                    else:
                        parameters = input_schema if input_schema else {"type": "object", "properties": {}}
                    schemas.append({
                        "type": "function",
                        "function": {
                            "name": f"mcp__{slug}__{t.name}",
                            "description": description,
                            "parameters": parameters,
                        }
                    })
                suffix = f" (attempt {attempt}/{max_attempts})" if attempt > 1 else ""
                logger.info(f"🔌 MCP {slug}: {len(tools_response.tools)} tool(s) loaded{suffix}")
                return
            except (Exception, BaseExceptionGroup) as e:
                last_error = e
                await stack.aclose()
                if attempt < max_attempts:
                    logger.warning(f"MCP slug '{slug}' attempt {attempt}/{max_attempts} failed: {e} — retrying")
                    await asyncio.sleep(0.75 * attempt)

        logger.warning(f"MCP slug '{slug}' unavailable after {max_attempts} attempt(s): {last_error}")
        failed_slugs.append({"slug": slug, "error": str(last_error)})

    active_slugs = [s for s in slugs if s and (user_email or s not in USER_SCOPED_MCP_SLUGS)]
    await asyncio.gather(*[_connect_slug(s) for s in active_slugs], return_exceptions=True)
    return schemas, sessions, failed_slugs


async def execute_mcp_tool(namespaced_name: str, arguments: dict, sessions: dict) -> str:
    """
    Execute an AI Gateway MCP tool by its namespaced name (mcp__{slug}__{tool}).
    Looks up the already-open session for that slug.
    """
    try:
        _, slug, tool_name = namespaced_name.split("__", 2)
    except ValueError:
        return f"Error: malformed MCP tool name '{namespaced_name}'"

    entry = sessions.get(slug)
    if not entry:
        return f"Error: no open MCP session for slug '{slug}'"
    session = entry["session"]
    if entry.get("user_email"):
        # Overwrite, never trust: whatever user_id the model sent is discarded.
        arguments = {**(arguments or {}), "user_id": entry["user_email"]}

    try:
        result = await session.call_tool(tool_name, arguments)
        parts = []
        for block in (result.content or []):
            if hasattr(block, "text"):
                parts.append(block.text)
            else:
                parts.append(str(block))
        return "\n".join(parts) if parts else "(empty result)"
    except Exception as e:
        return f"MCP tool '{tool_name}' error: {str(e)}"


# -----------------------------------------
# TOOL DISPATCHER
# Every tool lives behind the AI Gateway: MCP servers (mcp__{slug}__{tool}) and
# A2A sub-agents (a2a__{slug}). There are no locally-implemented tools.
# -----------------------------------------
async def execute_tool(tool_name: str, arguments: dict, mcp_sessions: dict = None, client=None, model: str = None) -> str:
    try:
        if tool_name.startswith("mcp__") and mcp_sessions:
            return await execute_mcp_tool(tool_name, arguments, mcp_sessions)
        elif tool_name.startswith("a2a__") and mcp_sessions:
            return await a2a_agents.execute_a2a_tool(tool_name, arguments, mcp_sessions)
        else:
            return f"Error: Tool '{tool_name}' not recognized."
    except Exception as e:
        return f"Error executing tool: {str(e)}"
