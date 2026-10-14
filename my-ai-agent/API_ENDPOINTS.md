# Agent Backend API Endpoints

All endpoints below are defined in `agent-backend/app/main.py` and served at `https://agent.matthewwan.dev:8443` (note the non-standard port) via the Caddy reverse proxy. This is the complete list — there are no other route files.

## Summary

| Endpoint | Method | Auth | Used by `client-chat-ui`? | Used by `agent-dashboard`? |
|---|---|---|---|---|
| `/ws` | WebSocket | Bearer or Basic (via `access_token` query param) | ✅ default chat transport | ❌ |
| `/api/v1/chat` | POST | Bearer or Basic | ✅ REST chat transport | ❌ |
| `/api/v1/chat/stream` | POST | Bearer or Basic | ✅ SSE chat transport | ❌ |
| `/api/v1/chat/public` | POST | **None** | ❌ | ❌ |
| `/api/v1/upload` | POST | Bearer or Basic | ✅ file attachments | ❌ |
| `/api/v1/feedback` | POST | **None** | ✅ 👍/👎 widget | ❌ |
| `/api/v1/client-config` | GET | **None** | ✅ on app load | ❌ |
| `/api/v1/auth/basic/verify` | POST | N/A (credential check itself) | ✅ from NextAuth's Credentials provider, server-side | ❌ |

**Note:** `/api/v1/feedback` and `/api/v1/client-config` have no `Depends(verify_request_auth)` — they're unauthenticated at the backend regardless of which UI calls them. This isn't a bug specific to those routes; they're non-sensitive (public UI bootstrap config, and a feedback forward that only needs a trace ID).

## Chat pipeline endpoints

These three (plus `/ws`) implement the **same pipeline** — intent classification → optional Prisma AIRS scan → load session history from Redis → LLM call (optionally through a tool-use loop) → save history — just over different transports.

### `WS /ws`
Streaming chat over a WebSocket. `client-chat-ui`'s default "WebSocket (WSS)" connection mode (`useWebSocket.ts`). The browser WebSocket API can't set headers, so the token is passed as `?access_token=<Scheme value>` (URL-encoded). Opens a **new** connection per message rather than staying persistently connected. Emits JSON frames: `{"event": "connected"}`, `{"event": "agent_thinking", "payload": {"chunk": ...}}`, `{"event": "agent_stream", "payload": {"chunk": ...}}`, `{"event": "trace_id", ...}`, `{"event": "routing_info", ...}`, `{"event": "agent_complete", "payload": {"id": session_id}}`, or `{"event": "error", "payload": "..."}`.

### `POST /api/v1/chat`
Blocking REST call — `client-chat-ui`'s REST transport (`useREST.ts`). Request body (`ChatRequest`):
```json
{ "text": "...", "session_id": "optional", "security_mode": "secure|insecure", "task_type": "coding|writing", "user_info": {"id","email","name"} }
```
Response:
```json
{ "session_id": "...", "response": "...", "thinking": "...", "status": "success|error", "trace_id": "...", "routing_info": "..." }
```
Uses Portkey's `with_raw_response` to pull the AIRS-masked final text out of `hook_results`.

### `POST /api/v1/chat/stream`
Same request body as `/api/v1/chat`, but returns a `text/event-stream` — `client-chat-ui`'s SSE transport (`useSSE.ts`). Each `data:` line is a JSON object with a `type` of `thinking`, `content`, `trace_id`, `session_id`, or `routing_info`, terminated by `data: [DONE]`.

### `POST /api/v1/chat/public`
Identical pipeline to `/api/v1/chat` but with **no auth dependency at all** — reachable with no `Authorization` header. Exists for demoing/comparing unprotected vs. protected calls (e.g. via curl/Postman) but is **not wired into either frontend** currently. Keep this in mind for security reviews — it's intentionally open, not an oversight, but it's easy to forget it exists.

## Supporting chat endpoints

### `POST /api/v1/upload`
Multipart upload (`file` + `session_id` form fields), authenticated. Extracts text (or, for vision-capable models, image content) from the file and injects it into that session's Redis-stored message history as a synthetic user/assistant turn pair, so the next chat turn has the file's content in context. Used by `client-chat-ui`'s `ChatPane.tsx` for file attachments.

### `POST /api/v1/feedback`
Forwards a 👍/👎 (1–5 value) rating to Portkey's feedback API, keyed by `trace_id` (or updates an existing `feedback_id`). No-op (`{"status": "skipped"}`) when `gateway_mode` is Direct, since there's no Portkey trace to attach it to. Used by `client-chat-ui`'s `FeedbackWidget.tsx`.

### `GET /api/v1/client-config`
Public bootstrap endpoint — returns the live `connection_method` (websocket/rest/sse default) and `gateway_mode` from Redis so the UI can initialize its transport selector on load. Used by `client-chat-ui`'s `WorkspaceShell.tsx`.

### `POST /api/v1/auth/basic/verify`
Validates a `Basic` header against `BASIC_AUTH_USERS` and returns `200`/`401`. Not called directly by the browser — it's invoked server-side from `client-chat-ui/src/lib/auth.ts`'s NextAuth Credentials provider `authorize()` function during login, so bad username/password pairs are rejected at sign-in rather than on the first chat message.

## Auth internals (not routes, but relevant)

`verify_request_auth` (the dependency behind every "Bearer or Basic" row above) accepts either an `Authorization: Bearer <Idira JWT>` or `Authorization: Basic <base64>` header and validates accordingly — see [AUTHENTICATION.md](AUTHENTICATION.md) for the full flow.
