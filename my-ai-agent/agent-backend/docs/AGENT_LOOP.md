# Agentic Loop ("ReAct Loop") Architecture

This documents the tool-calling / agentic-RAG loop implemented in
`agent-backend/app/main.py` (function `run_react_loop`, plus the per-iteration
setup duplicated across all four chat endpoints) and the tool dispatcher in
`agent-backend/app/tools.py`. It's a code review + architecture reference, not
a tutorial — it assumes familiarity with the top-level CLAUDE.md.

## 1. Where the loop sits in the request pipeline

Every one of the four chat endpoints (`WS /ws`, `POST /api/v1/chat`,
`POST /api/v1/chat/stream`, `POST /api/v1/chat/public`) runs the same
pipeline, just with a different transport wrapping it:

```
load live config (Redis)  →  load + trim session history (Redis)
   →  append user message  →  open tool schemas (local + MCP)
   →  Phase 1: one LLM call with tools attached
        ├─ no tool_calls  → response is final, done
        └─ tool_calls     → execute them, then hand off to run_react_loop()
   →  run_react_loop(): up to 5 further LLM calls, executing tools as needed
   →  persist updated history (Redis)  →  emit trace ID + activity log
```

"Phase 1" (the first LLM call) is **not** part of `run_react_loop` — it's
duplicated inline in each of the four handlers (e.g. `main.py:839-893` for
WS). `run_react_loop` only handles the *second* LLM call onward, once Phase 1
has already produced at least one tool call. This split is why CLAUDE.md
warns that pipeline changes usually have to be made in four places: anything
touching Phase 1 behavior (streaming accumulation, tool-call parsing, the
"Iteration 1" UI message) lives in each handler separately, while anything
touching iteration 2+ lives once in `run_react_loop` and is shared.

## 2. The loop itself — `run_react_loop` (`main.py:579-760`)

Signature:

```python
async def run_react_loop(
    active_client, actual_model, messages, tool_schemas,
    current_trace_id, portkey_metadata,
    on_tool_start=None, on_tool_done=None, on_content=None,
    max_iterations=5,
    mcp_sessions=None,
)
```

Each of the `max_iterations` (default 5) iterations makes one streaming
`chat.completions.create` call and does three things concurrently as chunks
arrive:

- buffers tool-call delta fragments into `tool_calls_dict` (see §3)
- appends content deltas to `content_chunks`
- **streams content live** via `on_content(chunk)`, but only while no tool
  call has been seen yet this iteration (`if not tool_calls_dict`) — this is
  what lets a plain conversational answer stream to the client token-by-token
  even though the code doesn't know in advance whether this turn will end in
  tool calls or not

After the stream ends, the iteration branches on whether tool calls were
found:

- **Tool calls, not the last iteration** → execute them (`tools.execute_tool`
  per call, deduped — see §4), append results as `role: tool` messages,
  optionally inject system notices (§5), call `on_tool_done`, loop again.
- **No tool calls, or this is the forced-last iteration** → treat
  `"".join(content_chunks)` as the final answer, append it to history, and
  `break`.

### Iteration budget

The loop is a hard, count-bounded cap — there's no wall-clock timeout, only a
call-count one. `max_iterations` defaults to 15 (`main.py:583`; raised from
the original 5 — see §8 note on the tradeoff), and none of the four handlers
override it, so this one default applies everywhere:

| Call | Where | Can execute tools? |
|---|---|---|
| 1 (Phase 1) | inline in each handler | yes |
| 2–15 (loop iterations 1–14) | `run_react_loop` | yes |
| 16 (loop iteration 15) | `run_react_loop` | **no — forced-final** |

So a single user turn makes **at most 16 LLM calls total**, of which at most
15 can execute tools. `iterations_used` (returned as `extra_iters`) only
counts loop iterations that executed tools, so `total_iters = 1 + extra_iters`
maxes out at 15 — matching the "✅ Completed N retrieval iteration(s)" message
shown to the user, which never reports the forced-synthesis call since it
isn't a retrieval step. (The worked example throughout this doc, and the
incident in §8, happened under the original cap of 5 / 6 total calls — the
mechanics described are unchanged, only the ceiling moved.)

### The forced-final-iteration guardrail

On the last iteration (`is_last_iteration = iteration == max_iterations`),
the call keeps the tool schemas but sends `tool_choice: "none"`, which tells
the model it may not call a tool this turn. This exists specifically because,
without it, a model that keeps wanting to call tools could exhaust the
iteration budget and the loop would exit with an empty `final_text` (this
was the bug fixed in commit `d7d2edd` and its follow-up `18646b2`).

It used to drop the tool schemas instead (`tools=None`). That was weaker:
with a history full of tool calls, some models kept calling tools anyway,
writing a lead-in sentence and then a tool call, and some providers reject
tool turns when no tools are declared.

The code still defensively assumes a gateway/model combination may emit
`tool_calls` on this turn anyway (observed in production via Portkey). On the
forced-final iteration those tool calls are **ignored outright** — never
executed — since there's no further iteration left to feed their results
back into. Its text keeps streaming to the user even after a tool call
starts, since all of it is the answer (otherwise the reply appeared cut off
mid-sentence). If the model also produced no text content in that case, a
canned fallback string is substituted so the user never sees a blank
response:

```python
final_text = ("I wasn't able to finish researching this within my tool-call "
              "budget, so I don't have a confident final answer. ...")
```

Because this fallback is synthesized *after* the stream ends, it never goes
through the normal per-chunk `on_content` path. The WS and SSE handlers
build the entire message shown to the user by accumulating live `on_content`
calls and **discard `run_react_loop`'s return value** (`_, extra_iters, ... =
await run_react_loop(...)`), so without an explicit extra call the fallback
would be computed correctly internally but never reach those two transports
— exactly the bug found and fixed in this session (`main.py:753-759`):

```python
if on_content is not None:
    await on_content(final_text)
```

The REST handlers (`/api/v1/chat`, `/api/v1/chat/public`) don't pass
`on_content` at all — they use the returned `final_text` directly to build
the JSON response — so they were never affected by this gap.

## 3. Tool-call delta accumulation — `accumulate_tool_call_delta` (`main.py:32-66`)

Streamed tool calls arrive as fragments (`index`, partial `id`,
partial `function.name`/`arguments`) that must be reassembled. This
function exists because different providers behind the same Portkey gateway
fragment differently:

- **OpenAI/DeepSeek**: `tc.index` is stable and unique per parallel tool
  call — fragments correlate by index.
- **Gemini** (via Portkey's OpenAI-compat translation): sends `index=0` for
  *every* parallel tool call in a turn, each as one complete fragment with
  its own `id`. Keying purely by index would merge unrelated calls into one
  corrupted entry (concatenated names/args).

The function detects a new `tc.id` reusing an index already bound to a
different id, and gives it its own composite key (`(idx, tc_id)`) instead of
clobbering the existing entry. This is shared by all four handlers' Phase 1
accumulation loops and by `run_react_loop`.

## 4. Repeated-call dedup (`run_react_loop`, `seen_tool_calls`)

Within a single loop run, `seen_tool_calls` maps a canonical key
(`f"{name}::{json.dumps(args, sort_keys=True)}"`) to its result. If the model
issues the exact same tool + arguments twice, the cached result is reused
instead of re-executing, and a `[SYSTEM NOTICE]` user-role message is
injected telling the model not to repeat identical calls and to either try a
different query or answer with what it already has.

**Limitation**: this only catches byte-identical `(tool, args)` pairs. A
search/RAG-style MCP tool that does its own query rewriting server-side can
still receive two differently-phrased but semantically-equivalent calls from
the model without deduping — the model can still burn iterations on
near-duplicate lookups. This is a reasonable tradeoff (semantic dedup would
need an embedding comparison per call) but worth knowing as a boundary of the
safeguard.

There's also a pair of escalating warnings tied to the same countdown, fired
from `remaining_tool_iterations = (max_iterations - 1) - iteration` (i.e. how
many *more* tool-having iterations remain after this one):

- `remaining_tool_iterations == 1` → "you have one more opportunity to call a
  tool" — correctly refers to the next iteration, which can still call
  tools.
- `remaining_tool_iterations == 0` → "tool access ends now, your next turn
  has no tools" — refers to the upcoming forced-final
  (`tool_choice: "none"`) iteration.

**(Fixed — was previously a bug)** These used to be a single check
(`max_iterations - iteration == 1`), which fired one iteration too late: it
told the model "you have one more opportunity to call a tool" *immediately
before the forced-final, tools=None iteration* — i.e. right as that
opportunity was actually being revoked, not granted. A model that took the
notice at face value would spend its forced-final turn trying to use a tool
call it was never going to get instead of answering, landing on the
generic fallback with a fully exhausted budget and nothing to show for it.
Splitting it into two accurate, iteration-appropriate notices (above) fixes
that off-by-one.

## 5. Tool dispatch — `tools.py`

There are no locally-implemented tools left. SearxNG (`searxng_web_search`),
Ollama web search (`ollama_web_search`), and ChromaDB RAG
(`search_internal_docs`) were removed in turn — all superseded by the MCP
tool design below. `tools.py` now contains only the MCP helpers.

`mcp_sessions_context` (`main.py:184-207`) opens sessions against
MCP servers hosted behind the AI Gateway's own MCP port (configured via
`config:mcp_gateway_url` / `config:mcp_server_slugs`, distinct from the
chat-completions gateway URL) and converts their tool listings into OpenAI
schema shape with names namespaced as `mcp__{slug}__{tool}` — this is the
entire `tool_schemas` list the loop sees.

A2A sub-agents (`a2a_agents.py`) are loaded alongside, in the same
`mcp_sessions_context`: each enabled agent from `config:a2a_agents` becomes one
tool `a2a__{slug}` with a single `message` parameter, and its client lives in the
same sessions dict under an `a2a:{slug}` key so it closes with the MCP sessions.
Delegation sends one A2A message (polling the task if it isn't finished) and
returns the sub-agent's reply text as the tool result; a sub-agent asking for
more input comes back as "The sub-agent needs more information: …".

`execute_tool` (`tools.py`) is the single dispatch point used by both
Phase 1 and `run_react_loop`: it routes any `mcp__`-prefixed name to
`execute_mcp_tool` and any `a2a__`-prefixed name to `execute_a2a_tool`, catching exceptions and returning them as a string result
(rather than raising) so a single failed tool call degrades to an error
message the model can react to instead of aborting the whole turn.

`get_mcp_tool_schemas` retries each slug's connection up to twice with
backoff (MCP-over-HTTP cold-start failures are apparently common enough in
practice to warrant this) and reports unreachable slugs back to the caller
as `failed_slugs`, which each handler surfaces to the user as a "tool(s)
unavailable this turn" notice rather than silently proceeding as if no tools
were configured.

## 6. Observability hooks

- **Trace ID**: one `uuid4` generated per request, reused via
  `x-portkey-trace-id` across Phase 1, every loop iteration, and any AIRS/etc.
  calls, so Portkey's dashboard can group them as one logical turn.
- **Per-iteration activity log**: `extract_portkey_activity` pulls
  cache-status/retry-count/provider/model/token-usage off each raw Portkey
  response and labels it — `"Tool call"`, `"Synthesis"`, or `"Forced
  synthesis (iteration cap reached)"`. `format_portkey_activities` renders
  the accumulated list for the UI's routing-info panel.

  **Review finding**: the label is chosen by `if tool_calls_dict: "Tool
  call" elif is_last_iteration: "Forced synthesis..." else: "Synthesis"`
  (`main.py:677-682`) — it checks `tool_calls_dict` truthiness *before*
  `is_last_iteration`. So on the forced-final iteration, if the model still
  emits (discarded) tool calls, the activity is mislabeled `"Tool call"`
  instead of `"Forced synthesis (iteration cap reached)"`, even though those
  calls were never executed. This is purely a display/observability
  inaccuracy in the Portkey activity panel — it doesn't affect loop behavior
  — but it can make the "iteration cap was hit and the model was overridden"
  case harder to spot from the activity log alone.

## 7. Session/history interaction

History is loaded per-session from Redis (`session:{id}`, 1h TTL), trimmed to
system message + last 20 messages *before* the loop starts, and the system
prompt slot (`messages[0]`) is always overwritten with the current live
prompt. The loop itself freely appends assistant tool-call, tool-result and
system-notice messages to the same `messages` list for the duration of one
request; only the final state (after the loop returns) is persisted back to
Redis by the calling handler. The loop does **not** append the final answer:
each handler appends its own (diagram-fenced) version exactly once before
saving. (It used to append it too, which stored every tool-using reply twice.) Mid-loop messages (tool results, repeat-call notices, the
"one more call" nudge) are not trimmed independently — they count against
the same 20-message trim window on the *next* turn, so a turn with many tool
calls can push earlier conversation turns out of history sooner than a
turn with none.

## 8. Summary of review findings

1. **(Fixed)** WS/SSE clients could receive a blank final message on the
   forced-final-iteration fallback path, because that fallback text was
   never routed through `on_content`. Fixed in `main.py:753-759`.
2. **(Fixed)** The "you have one more opportunity to call a tool" warning
   fired one iteration too late — right before the forced-final (`tools=
   None`) iteration instead of before the last iteration that actually still
   had tools. A model that trusted the notice would spend its forced-final
   turn attempting a tool call that was silently discarded, rather than
   answering, exhausting the entire budget for nothing (observed live: a
   6-call, ~30k-token GitHub-research turn that ended in the generic
   fallback). Fixed in `main.py:734-751` by splitting it into two accurate,
   iteration-appropriate notices — see §4.
3. **(Minor, cosmetic)** Activity-log mislabeling when the model emits
   discarded tool calls on the forced-final iteration (`main.py:677-682`) —
   shows as `"Tool call"` instead of `"Forced synthesis (iteration cap
   reached)"`. This was actually the tell that made finding #2 above
   diagnosable from the Portkey activity log alone (the 6th/last call showed
   as `"Tool call"`, meaning the model attempted one right when it shouldn't
   have been trying to).
4. **(Design tradeoff, not a bug)** Repeated-call dedup is exact-match only;
   rephrased-but-equivalent RAG/code-search queries aren't caught. This is
   part of why the GitHub-research turn above could burn 5 iterations on
   `search_code` variants without ever tripping the repeat-call notice.
5. **(Maintenance risk, flagged in CLAUDE.md already)** Phase 1's streaming/
   accumulation/tool-execution logic is duplicated near-verbatim across all
   four handlers rather than factored out like `run_react_loop` was for
   iterations 2+. Any future Phase-1-level fix needs to be applied in four
   places by hand.
6. **(Characteristic, not necessarily a problem)** The iteration cap is
   call-count-based only (max 16 LLM calls/turn as of the current default)
   with no wall-clock timeout — a turn with several slow MCP tool round-trips
   has no upper bound on total latency, only on call count. It's also a flat
   cap regardless of task: a broad "research this GitHub repo" style ask has
   no more budget than a single targeted internal-docs lookup. This was part
   of why the incident in finding #2 ran out of room (under the then-default
   cap of 5) before reaching a file it could actually read (e.g. the README)
   instead of only searching code snippets — raising the default to 15 gives
   that kind of multi-step task much more room, at the cost of a much larger
   worst-case token bill and latency per turn (context grew from 588 to 7,470
   prompt tokens in just 6 calls in that incident; a 16-call worst case could
   run substantially higher, with some risk of hitting the model's context
   limit before it ever answers).
