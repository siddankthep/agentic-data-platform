# Building a Cube MCP server in Python

A guiding doc: what MCP actually is, how an agent uses it, and the smallest
useful server that exposes this project's Cube semantic layer. Code here is
meant to be typed out by you, not copy-pasted blindly — each block explains the
decision behind it.

---

## 1. The mental model

### What MCP is

MCP (Model Context Protocol) is a **JSON-RPC protocol between a host app and a
tool server**. That's all. The LLM never speaks MCP. The flow is:

```
┌────────────┐   MCP (JSON-RPC)   ┌────────────┐   HTTP    ┌──────┐   SQL   ┌──────────┐
│  MCP host  │◄──────────────────►│ MCP server │◄─────────►│ Cube │◄───────►│ Postgres │
│ (Claude    │  stdio or HTTP     │ (your      │  REST     │      │         │          │
│  Code, …)  │                    │  Python)   │           │      │         │          │
└─────┬──────┘                    └────────────┘           └──────┘         └──────────┘
      │ Messages API (tools=[...])
      ▼
   ┌──────┐
   │ LLM  │
   └──────┘
```

The host does three jobs:
1. On startup, calls `tools/list` on your server and gets JSON Schemas.
2. Passes those schemas to the model as tool definitions.
3. When the model emits a tool call, the host calls `tools/call` on your server
   and feeds the result back into the conversation.

So **your MCP server is a plain function library with a machine-readable
description**. The "agentic" part lives entirely in the host's loop.

### The agentic loop (what you're really building for)

```
user question
   └─► model sees tool schemas
        └─► calls describe_semantics()          # discover what exists
             └─► calls run_query({...})         # attempt
                  └─► error: "invalid member"   # <- this is normal, and useful
                       └─► calls run_query({...}) again, corrected
                            └─► natural-language answer + numbers
```

Two design consequences that matter more than anything else:

- **Tool descriptions are prompt.** The model picks tools by reading them. A
  vague description is a bug.
- **Errors are prompt too.** Return `"Unknown measure 'orders.revenue'. Available
  measures: ..."` rather than a stack trace. The model can self-correct from the
  first and cannot from the second.

### Why Cube is the right thing to wrap

The naive alternative is a `run_sql` tool. Then the model must invent joins,
remember that `total_price` lives on `order_items`, and avoid fan-out
double-counting. It will get this wrong.

Cube's semantic layer already encodes joins, grain, and measure definitions
(see [order_economics.yml](../cube_semantics/model/views/order_economics.yml) —
item revenue and payment value are pre-aggregated independently so combining
them is safe). Wrapping Cube means **the model picks names from a closed
vocabulary instead of authoring SQL**. Correctness moves out of the prompt and
into YAML you control.

---

## 2. The Cube API surface you need

Only two endpoints. Cube runs in dev mode here (`CUBEJS_DEV_MODE=true`), so no
auth token is required; in production you'd send `Authorization: <JWT>`.

**Metadata** — `GET http://localhost:4000/cubejs-api/v1/meta`

Returns every cube and view with its measures, dimensions, types and
descriptions. This is your "schema for the model".

**Query** — `POST http://localhost:4000/cubejs-api/v1/load`

```json
{"query": {
  "measures": ["order_economics.order_items_total_price"],
  "dimensions": ["order_economics.order_status"],
  "timeDimensions": [{
    "dimension": "order_economics.order_purchase_timestamp",
    "granularity": "month",
    "dateRange": ["2017-01-01", "2017-12-31"]
  }],
  "filters": [{"member": "order_economics.order_status", "operator": "equals", "values": ["delivered"]}],
  "order": {"order_economics.order_items_total_price": "desc"},
  "limit": 100
}}
```

Response has `data` (list of row dicts) and `annotation` (per-member metadata).
Cube may return HTTP 200 with `{"error": "..."}` — check for that, don't rely on
status codes alone.

Poke both with `curl` before writing any Python. You cannot design a good tool
around an API you haven't seen respond.

---

## 3. Tool design — the actual decision

The temptation is many tools (`list_cubes`, `get_measures`, `query_orders`, …).
Resist it. Every tool costs context in the system prompt and adds a chance of
wrong selection.

**Three tools is the right number here:**

| Tool | Purpose | Why it exists separately |
|---|---|---|
| `describe_semantics(view=None)` | Compact listing of views/measures/dimensions | Discovery. Called first, almost always. |
| `run_query(...)` | Execute a Cube query, return rows | The workhorse. |
| `explain_query(...)` *(optional)* | Return the SQL Cube would run | Trust/debugging; drop it if you want minimum effort. |

Design notes worth internalising:

- **Don't dump raw `/meta`.** It's tens of KB of JSON. Flatten it to
  `view.member — type — description` lines. Context is the scarce resource.
- **`describe_semantics` takes an optional `view`** so the model can go
  coarse → fine instead of paying for everything up front.
- **`run_query` mirrors Cube's query shape** (measures / dimensions /
  time_dimensions / filters / order / limit). Don't invent your own DSL — the
  model has likely seen Cube's JSON format in training, and you avoid writing a
  translation layer that can be wrong.
- **Always cap `limit`.** A 100k-row result blows the context window. Cap at
  ~500 server-side and say so in the response when truncated.

---

## 4. Implementation

`mcp[cli]` is already in [pyproject.toml](../pyproject.toml). Add `httpx`:

```bash
uv add httpx
```

Create `cube_mcp_server/server.py`. The whole server is ~120 lines. The working
implementation lives at [server.py](../cube_mcp_server/server.py) — read this
section first, then compare.

### 4.1 Skeleton

```python
import os
import httpx
from mcp.server import MCPServer

CUBE_URL = os.getenv("CUBE_API_URL", "http://localhost:4000/cubejs-api/v1")
CUBE_TOKEN = os.getenv("CUBE_API_TOKEN")  # unused in dev mode

mcp = MCPServer("cube-semantics")

def _client() -> httpx.Client:
    headers = {"Authorization": CUBE_TOKEN} if CUBE_TOKEN else {}
    return httpx.Client(base_url=CUBE_URL, headers=headers, timeout=60)
```

**Version note:** this project pins `mcp>=2.0.0`, where the server class is
`mcp.server.MCPServer`. Most tutorials you'll find online show
`from mcp.server.fastmcp import FastMCP`, which is the 1.x name for the same
thing — the decorator API is identical, only the import moved.

`MCPServer` turns a decorated Python function into an MCP tool: the **function
name** becomes the tool name, the **docstring** becomes the description, and
**type hints** become the JSON Schema. That's why the type hints below are not
cosmetic — they're the contract the model sees.

### 4.2 `describe_semantics`

```python
@mcp.tool()
def describe_semantics(view: str | None = None) -> str:
    """List the available Cube views with their measures and dimensions.

    Call this FIRST, before run_query, to learn the exact member names.
    Pass `view` to get full detail for one view; omit it for an overview
    of all views. Member names are always `view_name.member_name`.
    """
    with _client() as c:
        meta = c.get("/meta").json()

    lines = []
    for cube in meta["cubes"]:
        if view and cube["name"] != view:
            continue
        lines.append(f"\n## {cube['name']}")
        if cube.get("description"):
            lines.append(cube["description"].strip())
        # Overview mode: names only, keep it cheap.
        detail = view is not None
        for kind in ("measures", "dimensions"):
            lines.append(f"{kind}:")
            for m in cube.get(kind, []):
                if detail:
                    desc = f" — {m['description']}" if m.get("description") else ""
                    lines.append(f"  {m['name']} ({m['type']}){desc}")
                else:
                    lines.append(f"  {m['name']}")
    return "\n".join(lines) or f"No view named {view!r}."
```

Note the docstring does real work: it tells the model *when* to call this, and
the `view.member` naming rule that prevents the most common failure.

### 4.3 `run_query`

```python
@mcp.tool()
def run_query(
    measures: list[str] | None = None,
    dimensions: list[str] | None = None,
    time_dimensions: list[dict] | None = None,
    filters: list[dict] | None = None,
    order: dict | None = None,
    limit: int = 100,
) -> str:
    """Run a query against the Cube semantic layer and return the rows.

    All member names must come from describe_semantics and be fully
    qualified (`order_economics.order_status`).

    time_dimensions: [{"dimension": "...", "granularity": "month",
                       "dateRange": ["2017-01-01", "2017-12-31"]}]
    filters:         [{"member": "...", "operator": "equals",
                       "values": ["delivered"]}]
    order:           {"order_economics.total_price": "desc"}

    Do NOT write SQL. Cube resolves joins and aggregation for you.
    """
    query = {"limit": min(limit, 500)}
    for key, val in (
        ("measures", measures), ("dimensions", dimensions),
        ("timeDimensions", time_dimensions), ("filters", filters),
        ("order", order),
    ):
        if val:
            query[key] = val

    with _client() as c:
        resp = c.post("/load", json={"query": query})
    payload = resp.json()

    if "error" in payload:
        # Feed the model something it can act on, plus the vocabulary.
        return (f"Cube rejected the query: {payload['error']}\n"
                f"Call describe_semantics to check member names.")

    rows = payload["data"]
    if not rows:
        return "Query succeeded but returned no rows. Try widening filters."
    head = "\t".join(rows[0].keys())
    body = "\n".join("\t".join(str(v) for v in r.values()) for r in rows)
    return f"{len(rows)} rows\n{head}\n{body}"
```

Three things to notice, because they generalise to every MCP server you write:

1. **Returning a string, not JSON.** Tool results are read by a language model.
   TSV is compact and perfectly legible to it; nested JSON wastes tokens.
2. **The error branch is a teaching message**, not an exception. An uncaught
   exception ends the agent's turn; a helpful string lets it retry.
3. **`limit` is clamped in code**, not merely documented. Never trust a model to
   respect a documented bound.

### 4.4 Entry point

```python
if __name__ == "__main__":
    mcp.run()  # stdio transport
```

`mcp.run()` defaults to **stdio**: the host launches your process and speaks
JSON-RPC over stdin/stdout. This is why you must never `print()` inside an MCP
server — stdout is the protocol channel. Log to stderr.

For a network-reachable server instead: `mcp.run(transport="streamable-http")`.
Start with stdio; it has no ports, no auth, no CORS.

---

## 5. Running and connecting it

Inspect it standalone first — this catches schema mistakes without an LLM in the
loop:

```bash
uv run mcp dev cube_mcp_server/server.py
```

Or drive the functions directly, which needs nothing but Python and a running
Cube — the fastest inner loop while you're still shaping the tools:

```bash
uv run python -c "
from cube_mcp_server.server import describe_semantics, run_query
print(describe_semantics.fn(view='order_economics'))
"
```

(`.fn` reaches past the decorator to the plain function.)

Then register with Claude Code:

```bash
claude mcp add cube -- uv run --directory /home/sid/Sid/Personal/agentic-data-platform \
  python cube_mcp_server/server.py
```

Verify with `/mcp` in an interactive session, then ask a real question:

> "What was monthly delivered-order revenue in 2017, and which month was best?"

Watch the tool calls. You should see `describe_semantics` → `run_query`, and if
the model guessed a member name wrong, a second corrected `run_query`. That
recovery loop *is* the agentic workflow — if you see it happen, you've understood
the thing you set out to understand.

---

## 6. What to try next, in order of value

1. **Break it on purpose.** Remove the member-name rule from the `run_query`
   docstring and re-ask. Watch failure rate change. This is the fastest way to
   feel that descriptions are prompt engineering.
2. **Add MCP Resources.** Tools are model-invoked; *resources* are host-attached
   read-only context (`@mcp.resource("cube://meta")`). Good for the semantic
   catalogue when you want it always present rather than fetched.
3. **Add a Prompt.** `@mcp.prompt()` exposes a reusable templated workflow
   ("analyse revenue drivers for {period}") as a slash command in the host.
4. **Cache `/meta`.** It's static between model reloads; refetching per call is
   pure latency.
5. **Then, and only then, build your own host loop** with the Claude Messages
   API + `tool_runner` to see the other side of the protocol.

Steps 1–4 teach you MCP. Step 5 teaches you agents. Doing them in that order is
much easier than doing both at once.
