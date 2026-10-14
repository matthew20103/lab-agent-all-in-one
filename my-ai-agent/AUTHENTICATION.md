# Authentication Architecture & Flow

This document describes how authentication currently works across the two stacks (`client-chat-ui/` and `agent-backend/`). It reflects the code as of the Okta → CyberArk Identity ("Idira") migration plus the subsequent token-refresh work.

## Overview

There are **two independent auth mechanisms**, both accepted by the backend on every authenticated endpoint:

| Method | Used for | Client-side | Backend validation |
|---|---|---|---|
| **OIDC via Idira** (`Bearer <JWT>`) | Normal end users | NextAuth.js custom OIDC provider (`id: 'cyberark'`, display name "Idira") | RS256 JWT signature check against Idira's JWKS |
| **HTTP Basic** (`Basic <base64(user:pass)>`) | Service/simple accounts | NextAuth Credentials provider, backed by a form on the sign-in page | Static `user:pass` map from `BASIC_AUTH_USERS` env var |

`agent-dashboard` (the admin Streamlit/Next dashboard) is **not** part of either flow — it's gated purely by Caddy `basicauth` at the reverse-proxy layer, unrelated to the app-level auth described here.

## Components

- **`client-chat-ui/src/lib/auth.ts`** — the single NextAuth config: both providers, JWT/session callbacks, token refresh logic.
- **`client-chat-ui/src/middleware.ts`** — Next.js middleware that runs NextAuth's `auth()` on every non-API, non-static route and redirects unauthenticated users to `/auth/signin` (via the `authorized()` callback in `auth.ts`).
- **`client-chat-ui/src/app/auth/signin/page.tsx`** — sign-in UI: an "Sign in with Idira" button (`signIn('cyberark', ...)`) plus a username/password form (`signIn('credentials', ...)`).
- **`client-chat-ui/src/hooks/useAgentStream.ts`** + `useWebSocket.ts`/`useSSE.ts`/`useREST.ts` — attach the session's token to every chat request and handle auth failures mid-request.
- **`agent-backend/app/main.py`** — validates every incoming request's `Authorization` header (or, for WebSocket, the `access_token` query param) independent of the client.

## Sign-in flow (Idira/OIDC)

1. User clicks **"Sign in with Idira"** on `/auth/signin` → `signIn('cyberark', { callbackUrl: '/' }, { prompt: 'login' })`.
2. NextAuth redirects to Idira's authorization endpoint, discovered automatically from `{CYBERARK_ISSUER}/.well-known/openid-configuration` (the provider is configured as a generic `type: 'oidc'` entry, not a named/prebuilt provider). Requested scope is `openid email profile offline_access` — `offline_access` is included so Idira issues a refresh token even if that isn't implied by the app's "Issue refresh tokens" toggle alone.
3. User authenticates with Idira; Idira redirects back to NextAuth's callback route with an authorization code.
4. NextAuth exchanges the code for tokens and invokes the `jwt()` callback with `account` populated:
   ```ts
   token.accessToken = account.access_token
   token.accessTokenExpires = account.expires_at * 1000
   token.refreshToken = account.refresh_token
   token.authMethod = 'cyberark'
   ```
5. The `session()` callback exposes `accessToken`, `authMethod`, and `error` on the client-visible `session` object (NextAuth's default session type is extended via these ad-hoc fields rather than a typed module augmentation).
6. The encrypted session (a JWT, since this app uses NextAuth's `strategy: 'jwt'` — the default when no database adapter is configured) is stored in a cookie with `session.maxAge` set to **365 days**, matching Idira's refresh-token absolute lifetime.

## Sign-in flow (Basic Auth)

1. User submits username/password on `/auth/signin`'s form → `signIn('credentials', { username, password, callbackUrl: '/', redirect: false })`.
2. The Credentials provider's `authorize()` builds a `Basic <base64(user:pass)>` header and POSTs it to the backend's `POST /api/v1/auth/basic/verify`, which checks it against `BASIC_AUTH_USERS` (a `user:pass,user2:pass2` env var parsed into a dict) and returns `200`/`401`. This means bad credentials are rejected at login time, not on the first chat message.
3. On success, `jwt()` stores the header itself as the "token": `token.accessToken = "Basic <base64>"`, `token.authMethod = 'basic'`. There is no expiry and no refresh path for this method — it's a static shared secret.

## Per-request flow (both methods)

`useAgentStream.ts`'s `getToken()` builds the exact `Authorization` header value to send:
```ts
authMethod === 'basic' ? accessToken /* already "Basic <b64>" */ : `Bearer ${accessToken}`
```
This is passed into whichever transport hook is active:

- **REST** (`useREST.ts`) / **SSE** (`useSSE.ts`) — sent as a normal `Authorization` header on `POST /api/v1/chat` / `POST /api/v1/chat/stream`.
- **WebSocket** (`useWebSocket.ts`) — the browser `WebSocket` API can't set custom headers, so the full header value is passed as a URL-encoded `access_token` query param on `wss://.../ws`. Each chat message opens a **new** short-lived WebSocket connection (not one persistent socket), so every send re-fetches a fresh token via `getToken()`.

### Backend validation (`agent-backend/app/main.py`)

- `verify_request_auth(request)` — a FastAPI dependency used by `/api/v1/chat`, `/api/v1/chat/stream`, and `/api/v1/upload`. Reads `Authorization`, splits on scheme:
  - `Bearer <token>` → `validate_jwt(token)`: fetches the signing key from Idira's JWKS via `PyJWKClient(CYBERARK_JWKS_URI)`, decodes RS256, and checks `audience=CYBERARK_AUDIENCE, issuer=CYBERARK_ISSUER` (which includes standard `exp` enforcement — an expired token is rejected automatically).
  - `Basic <token>` → `validate_basic_auth(token)`: base64-decodes, compares against `BASIC_AUTH_USERS`.
  - Anything else, or a failure in either branch → `401 Unauthorized`.
- The `/ws` WebSocket handler duplicates this same scheme-based check inline (it can't use a FastAPI `Depends` on an already-accepted WebSocket connection), reading the header or the `access_token` query param, and closes the socket on failure:
  ```python
  await websocket.send_json({"event": "error", "payload": "Missing Token"})
  await websocket.close(code=1008, reason="Missing Token")
  # or
  await websocket.send_json({"event": "error", "payload": "Invalid Token"})
  await websocket.close(code=1008, reason="Invalid Token")
  ```
- `POST /api/v1/chat/public` has **no** auth dependency at all — intentionally open, for demo/comparison purposes.
- `CYBERARK_ISSUER` / `CYBERARK_AUDIENCE` / `CYBERARK_JWKS_URI` have no hardcoded fallback — they must be set in `agent-backend/.env`.

## Token refresh (Idira sessions only)

Idira's Tokens tab issues short-lived access tokens (currently 5 hours) alongside longer-lived refresh tokens (365-day absolute lifetime, optionally with an idle-lifetime cutoff, and a "Refresh token behavior" of either persistent or rotate-after-use). `auth.ts` handles this with two layers:

**1. Proactive refresh — `jwt()` callback in `auth.ts`:**
- On every invocation, if `authMethod === 'cyberark'` and the token is within 5 minutes of `accessTokenExpires`, `refreshAccessToken(token)` runs before the callback returns.
- `refreshAccessToken` lazily discovers `token_endpoint` from the OIDC discovery document (cached in module scope) and POSTs a `grant_type=refresh_token` request.
- The response's `refresh_token` (if present) always overwrites the stored one — this works correctly whether Idira is configured to rotate refresh tokens or reuse a persistent one, without needing to know which mode is active.
- On failure, the token is marked `{ error: 'RefreshAccessTokenError' }`, which `session()` surfaces as `session.error` to the client.
- `client-chat-ui/src/app/layout.tsx` wraps the app in `<SessionProvider refetchInterval={5 * 60}>` so this check runs every 5 minutes regardless of tab focus (the refresh network call itself only actually fires once near expiry — the interval just makes `jwt()` run periodically).

**2. Reactive fallback — `useAgentStream.ts`:**
Proactive refresh covers the common case, but an in-flight request can still race an expiry (device sleep, clock skew). `sendMessage`'s transport callbacks detect the known auth-failure signatures — `"HTTP 401"` from REST/SSE, or `"Invalid Token"` / `"Missing Token"` from the WebSocket handler — and, on the *first* such failure only:
1. Call `update()` (NextAuth's session-refetch function) to force `jwt()` to run immediately.
2. If the returned session has a fresh `accessToken` and no `error`, retry the same transport call once with it.
3. Otherwise (refresh failed, or the retry also fails), call `signOut({ callbackUrl: '/auth/signin' })` for a clean re-login instead of leaving the chat stuck on a raw error.

Basic Auth sessions skip all of this — their "token" has no expiry concept.

## Environment variables

| Variable | Where | Purpose |
|---|---|---|
| `CYBERARK_ISSUER` | both stacks | Idira issuer URL, used for OIDC discovery on both the NextAuth provider (client) and JWT validation (backend) |
| `CYBERARK_AUDIENCE` | `agent-backend` | Expected `aud` claim when validating access tokens |
| `CYBERARK_JWKS_URI` | `agent-backend` | JWKS endpoint for RS256 signature verification |
| `CYBERARK_USER_CLIENT_ID` / `CYBERARK_USER_CLIENT_SECRET` | `client-chat-ui` | Idira app credentials for the NextAuth OIDC provider |
| `BASIC_AUTH_USERS` | `agent-backend` | `user:pass,user2:pass2` static credential map |
| `NEXTAUTH_SECRET` / `NEXTAUTH_URL` / `AUTH_TRUST_HOST` | `client-chat-ui` | Standard NextAuth session-cookie signing/config vars |

No hardcoded fallback values exist for any `CYBERARK_*` var — all must be set in the respective `.env` files.

## Not covered / out of scope here

- `agent-dashboard`'s auth is Caddy `basicauth`, entirely separate from everything above.
- DPoP and the old Okta provider have been fully removed; there is no dual-provider fallback.
