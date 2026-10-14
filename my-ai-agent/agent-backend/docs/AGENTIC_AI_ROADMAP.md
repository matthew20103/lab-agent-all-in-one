# Agentic AI Roadmap

Status: **proposal / parked** — architecture only, nothing implemented yet.

## 1. Current state vs. "agentic"

Today every chat endpoint (`WS /ws`, `POST /api/v1/chat`, `POST /api/v1/chat/stream`,
`POST /api/v1/chat/public`) runs one bounded ReAct loop per user turn:

```
intent classify → optional AIRS scan → load last-20-message history
  → LLM call → ≤ N MCP tool-call iterations (deduped, capped) → save history
```

That is a tool-*using* agent: one message in, one loop, one answer out. Nothing
persists except the raw transcript (1-hour TTL). There is no explicit goal, no
plan, no memory beyond the transcript, and no way to keep working after the
response is sent. `run_react_loop`'s iteration cap bounds a single tool burst;
it is not multi-step planning.

"Agentic AI" here means the system can:

1. decompose a goal into steps itself,
2. carry state/memory beyond the chat log,
3. judge its own intermediate results and correct course,
4. optionally keep working asynchronously, outside one request/response cycle.

## 2. Target architecture

```
                 ┌──────────────┐
  user goal ───► │   Planner    │  cheap model; goal → ordered/DAG steps
                 └──────┬───────┘
                        ▼
                 ┌──────────────┐      plan:{id} in Redis
                 │ Orchestrator │◄───► goal, steps, per-step status,
                 └──────┬───────┘      results, plan_trace_id
           for each step│
                        ▼
                 ┌──────────────┐
                 │   Executor   │  = existing run_react_loop, per step
                 │ (MCP tools,  │    (mcp_sessions_context, AIRS)
                 │  AIRS scan)  │
                 └──────┬───────┘
                        ▼
                 ┌──────────────┐  pass → next step
                 │    Critic    │  fail → back to Planner (replan)
                 └──────┬───────┘
                        ▼
                 final synthesis → user
```

| Component | What it is | Maps onto existing code |
|---|---|---|
| **Planner** | Turns the user goal (plus recalled memory) into structured steps, each naming the tool class it expects to need | Same pattern as `determine_task_type()` (cheap classification call), but outputs a plan instead of `coding`/`writing` |
| **Plan state store** | `plan:{id}` in Redis, separate from `session:{id}`. Structured: goal, steps, status (pending/running/done/failed), per-step results, `plan_trace_id` | Extends the per-request Portkey trace ID to span every step of a plan |
| **Executor** | `run_react_loop`, called once per plan step instead of once per user message | Reuses MCP discovery and AIRS scanning unchanged |
| **Critic / Reflector** | Cheap LLM pass checking each step's result against its sub-goal; rejects trigger replanning instead of returning a half-answer | New; the main source of "agentic" behaviour |
| **Long-term memory** | Persistent facts/preferences/outcomes beyond the session TTL | An MCP server behind the AI Gateway (now available: `agent-memory` / mem0), so it stays "everything is MCP" |
| **Orchestrator** | Outer loop: Planner → [Executor → Critic] per step → replan or finish → synthesis | Today's per-turn pipeline becomes its inner primitive |

## 3. Phasing

Each phase ships independently.

1. **Plan–Act–Reflect, synchronous.** Add Planner and Critic around the existing
   loop, still within one HTTP/WS turn. No new infrastructure; the largest step
   from reactive tool use to deliberate multi-step reasoning.
2. **Persistent memory.** Use the mem0 `agent-memory` MCP server: the Planner
   recalls relevant memory before planning, and the Orchestrator stores
   outcomes/preferences after finishing. Depends on per-user identity being
   injected server-side into memory tool calls.
3. **Decouple from request/response.** Long goals shouldn't hold a WebSocket/SSE
   connection open. Add a task queue on the existing Redis (RQ or Celery) so a
   plan keeps running in the background; the client polls or receives pushed
   progress events using the existing `agent_thinking` / `agent_stream`
   vocabulary. This is where the system becomes autonomous in the literal sense.
4. **Multi-agent specialization (optional).** Split Planner/Executor/Critic into
   distinct role prompts or processes coordinated by the Orchestrator. Low
   priority: the platform's differentiator is guardrails, not agent
   sophistication.

## 4. Guardrail implications

More autonomy means a larger blast radius per guardrail miss.

- **AIRS at every step boundary**, not just the final response, so a plan that
  goes wrong at step 2 is caught at step 2.
- **Per-tool risk tiers.** Once the agent chains tool calls toward a
  self-generated plan, side-effecting tools (write/delete/send) need a higher
  trust tier or an explicit human-approval gate. Read-only tools (search, RAG,
  memory recall) can run freely. This extends the existing `secure`/`insecure`
  `security_mode`.
- **Identity is never model-chosen.** Per-user tools (e.g. memory) must get the
  user's identity from the verified auth token server-side, never from the LLM
  or the client request body.
- **Auditability.** A `plan_trace_id` spanning the whole multi-step (possibly
  background) run, so Portkey or the dashboard can show everything the agent did
  for one goal, not isolated per-turn traces.
