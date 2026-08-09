"""MCP server exposing this project's Cube semantic layer.

Design rationale lives in docs/mcp-cube-guide.md. The short version:

  * Three tools, not ten. Every tool costs system-prompt context and adds a
    chance of wrong selection.
  * Tool descriptions ARE prompt. The docstrings below are the only thing the
    model reads when deciding what to call.
  * Errors ARE prompt. Every failure path returns a string the model can act on
    — the offending name plus the valid vocabulary — never a stack trace. An
    uncaught exception ends the agent's turn; a teaching message lets it retry.
  * Views, not cubes, are the default surface. Views are the governed,
    intentional API of the semantic layer; raw cubes expose internals the model
    does not need and can misuse.

stdout is the JSON-RPC channel under the stdio transport, so nothing here may
print(). Diagnostics go to stderr.
"""

from __future__ import annotations

import difflib
import json
import logging
import os
import sys
import time
from typing import Any

import httpx

# MCP Python SDK 2.x. The 1.x class was `mcp.server.fastmcp.FastMCP`; the
# decorator API below is unchanged, only the import and the class name moved.
from mcp.server import MCPServer

CUBE_URL = os.getenv("CUBE_API_URL", "http://localhost:4000/cubejs-api/v1")
CUBE_TOKEN = os.getenv("CUBE_API_TOKEN")  # unused in dev mode

# Hard ceiling on rows returned to the model. A large result set does not make
# a better answer, it makes a truncated conversation. Clamped in code rather
# than merely documented — never trust a model to respect a documented bound.
MAX_ROWS = 500
META_TTL_SECONDS = 300

logging.basicConfig(stream=sys.stderr, level=logging.INFO)
log = logging.getLogger("cube-mcp")

mcp = MCPServer(
    "cube-semantics",
    instructions=(
        "Query the Olist marketplace semantic layer. Always call "
        "describe_semantics before run_query — member names cannot be guessed, "
        "and the member descriptions carry grain warnings that determine which "
        "one is correct. Never write SQL."
    ),
)


# ---------------------------------------------------------------------------
# Cube HTTP access
# ---------------------------------------------------------------------------


def _client() -> httpx.Client:
    headers = {"Authorization": CUBE_TOKEN} if CUBE_TOKEN else {}
    return httpx.Client(base_url=CUBE_URL, headers=headers, timeout=60)


class CubeError(Exception):
    """Cube refused the request. The message is written to be read by a model."""


def _post(path: str, payload: dict) -> dict:
    """POST to Cube, normalising its several failure shapes into one exception.

    Cube can fail in three different ways and only one of them is an HTTP
    error: a non-2xx status, a 200 carrying {"error": ...}, and a 200 carrying
    a continueWait retry signal. Collapsing them here keeps every tool's error
    handling to a single except clause.
    """
    with _client() as c:
        try:
            resp = c.post(path, json=payload)
        except httpx.ConnectError as exc:
            raise CubeError(
                f"Cannot reach Cube at {CUBE_URL}. Is the stack running "
                f"(`make up`)? Underlying error: {exc}"
            ) from exc
        except httpx.TimeoutException as exc:
            raise CubeError(
                "Cube did not respond within 60s. The query is probably scanning "
                "more data than a pre-aggregation covers — narrow the date range "
                "or reduce the number of dimensions."
            ) from exc

    try:
        body = resp.json()
    except ValueError:
        raise CubeError(f"Cube returned non-JSON (HTTP {resp.status_code}): {resp.text[:400]}")

    if isinstance(body, dict) and body.get("error"):
        raise CubeError(str(body["error"]))
    if resp.status_code >= 400:
        raise CubeError(f"HTTP {resp.status_code} from Cube: {json.dumps(body)[:400]}")
    return body


_meta_cache: tuple[float, dict] | None = None


def _meta(force: bool = False) -> dict:
    """Fetch /meta, cached. It only changes when the model files change."""
    global _meta_cache
    now = time.monotonic()
    if not force and _meta_cache and now - _meta_cache[0] < META_TTL_SECONDS:
        return _meta_cache[1]

    with _client() as c:
        try:
            resp = c.get("/meta")
        except httpx.HTTPError as exc:
            raise CubeError(
                f"Cannot reach Cube at {CUBE_URL}. Is the stack running (`make up`)? {exc}"
            ) from exc
    if resp.status_code >= 400:
        raise CubeError(f"HTTP {resp.status_code} fetching Cube metadata: {resp.text[:400]}")
    meta = resp.json()
    _meta_cache = (now, meta)
    return meta


# ---------------------------------------------------------------------------
# Metadata helpers
# ---------------------------------------------------------------------------


def _entries(include_cubes: bool) -> list[dict]:
    """Return views by default, cubes as well only when explicitly asked.

    Cube's /meta returns views and cubes in the same `cubes` array. Older
    versions omit the `type` discriminator, so fall back to returning
    everything rather than silently showing nothing.
    """
    all_entries = _meta().get("cubes", [])
    if include_cubes:
        return all_entries
    views = [e for e in all_entries if e.get("type") == "view"]
    return views or all_entries


def _member_index() -> dict[str, dict]:
    """Flat map of every queryable member name -> its metadata."""
    index: dict[str, dict] = {}
    for entry in _meta().get("cubes", []):
        for kind in ("measures", "dimensions", "segments"):
            for m in entry.get(kind, []):
                index[m["name"]] = {**m, "kind": kind, "parent": entry["name"]}
    return index


def _validate(names: list[str], expect: str | None = None) -> list[str]:
    """Check member names before Cube sees them, and explain any that are wrong.

    Catching this locally rather than forwarding Cube's terser message lets us
    attach a spelling suggestion and the parent's real member list — the two
    things that let a model fix itself on the next call instead of guessing
    again.
    """
    index = _member_index()
    problems: list[str] = []
    for name in names:
        meta = index.get(name)
        if meta is None:
            close = difflib.get_close_matches(name, index.keys(), n=3, cutoff=0.6)
            hint = f" Did you mean: {', '.join(close)}?" if close else ""
            if "." not in name:
                hint += (
                    " Member names must be fully qualified as "
                    "`view_name.member_name`."
                )
            problems.append(f"Unknown member {name!r}.{hint}")
        elif expect and meta["kind"] != expect:
            problems.append(
                f"{name!r} is a {meta['kind'][:-1]}, not a {expect[:-1]}. "
                f"Pass it in the `{meta['kind']}` argument instead."
            )
    return problems


def _rows_to_tsv(rows: list[dict], truncated: bool) -> str:
    """TSV, not JSON.

    Tool results are read by a language model. TSV carries the same information
    as nested JSON in a fraction of the tokens, and models parse it reliably.
    """
    header = list(rows[0].keys())
    lines = ["\t".join(header)]
    for row in rows:
        lines.append("\t".join("" if row.get(h) is None else str(row.get(h)) for h in header))
    note = (
        f"\n\n[Truncated to {len(rows)} rows. Narrow the query — aggregate further, "
        f"filter harder, or lower the granularity — rather than paging.]"
        if truncated
        else ""
    )
    return f"{len(rows)} rows\n" + "\n".join(lines) + note


def _build_query(
    measures: list[str] | None,
    dimensions: list[str] | None,
    time_dimensions: list[dict] | None,
    filters: list[dict] | None,
    order: dict | None,
    limit: int,
) -> dict:
    query: dict[str, Any] = {"limit": max(1, min(limit, MAX_ROWS))}
    for key, val in (
        ("measures", measures),
        ("dimensions", dimensions),
        ("timeDimensions", time_dimensions),
        ("filters", filters),
        ("order", order),
    ):
        if val:
            query[key] = val
    return query


def _collect_names(
    measures: list[str] | None,
    dimensions: list[str] | None,
    time_dimensions: list[dict] | None,
    filters: list[dict] | None,
) -> list[str]:
    names = list(measures or []) + list(dimensions or [])
    names += [td["dimension"] for td in (time_dimensions or []) if td.get("dimension")]
    names += [f["member"] for f in (filters or []) if f.get("member")]
    return names


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def describe_semantics(view: str | None = None, include_cubes: bool = False) -> str:
    """List the Cube views available to query, with their measures and dimensions.

    Call this FIRST, before run_query. It is the only source of valid member
    names — never guess one.

    Member names are always fully qualified: `view_name.member_name`.

    Args:
        view: Omit for a cheap overview of every view (names only). Pass a view
            name to get full detail for it — types and descriptions included.
            The descriptions carry grain warnings and metric definitions that
            change which member is correct, so read them before querying.
        include_cubes: Leave false. Views are the governed, intentional surface
            of this model. Set true only when you specifically need an internal
            cube that no view exposes.
    """
    try:
        entries = _entries(include_cubes)
    except CubeError as exc:
        return str(exc)

    if view:
        entries = [e for e in entries if e["name"] == view]
        if not entries:
            available = [e["name"] for e in _entries(include_cubes)]
            close = difflib.get_close_matches(view, available, n=3, cutoff=0.5)
            hint = f" Did you mean: {', '.join(close)}?" if close else ""
            return f"No view named {view!r}.{hint} Available: {', '.join(available)}"

    detail = view is not None
    out: list[str] = []
    for entry in entries:
        out.append(f"\n## {entry['name']}" + (f" — {entry['title']}" if entry.get("title") else ""))
        if entry.get("description"):
            out.append(entry["description"].strip())
        for kind in ("measures", "dimensions", "segments"):
            members = entry.get(kind, [])
            if not members:
                continue
            out.append(f"{kind}:")
            for m in members:
                if detail:
                    desc = f" — {m['description'].strip()}" if m.get("description") else ""
                    out.append(f"  {m['name']} ({m.get('type', '?')}){desc}")
                else:
                    out.append(f"  {m['name']}")

    if not detail:
        out.append(
            "\n[Overview only — names without descriptions. Call "
            "describe_semantics(view='<name>') before querying: the descriptions "
            "contain grain warnings that determine which member is correct.]"
        )
    return "\n".join(out)


@mcp.tool()
def run_query(
    measures: list[str] | None = None,
    dimensions: list[str] | None = None,
    time_dimensions: list[dict] | None = None,
    filters: list[dict] | None = None,
    order: dict | None = None,
    limit: int = 100,
) -> str:
    """Run a query against the Cube semantic layer and return the rows as TSV.

    Do NOT write SQL. Cube resolves joins, grain and aggregation from the
    model — that is the entire point of querying through it. Every member name
    must come from describe_semantics and be fully qualified.

    Args:
        measures: Aggregated values, e.g. ["order_economics.distinct_orders"].
        dimensions: Attributes to group by, e.g. ["order_economics.order_status"].
        time_dimensions: [{"dimension": "order_economics.order_purchase_timestamp",
            "granularity": "month", "dateRange": ["2017-01-01", "2017-12-31"]}].
            Use this rather than a filter for anything date-shaped —
            granularity is how you get a time series, and it is what lets Cube
            route the query to a pre-aggregation.
        filters: [{"member": "...", "operator": "equals", "values": ["delivered"]}].
            Operators include equals, notEquals, contains, gt, gte, lt, lte,
            set, notSet, inDateRange.
        order: {"order_economics.distinct_orders": "desc"}.
        limit: Rows to return. Clamped to 500. Prefer aggregating over paging —
            ask for a grouped summary, not raw rows.

    Returns rows as TSV, or a message explaining what was wrong with the query.
    """
    problems = []
    try:
        problems = _validate(_collect_names(measures, dimensions, time_dimensions, filters))
    except CubeError as exc:
        return str(exc)
    if problems:
        return (
            "Query not sent — invalid member names:\n  "
            + "\n  ".join(problems)
            + "\nCall describe_semantics(view=...) for the exact vocabulary."
        )

    if not measures and not dimensions and not time_dimensions:
        return (
            "A query needs at least one measure, dimension or time dimension. "
            "Call describe_semantics first to pick members."
        )

    query = _build_query(measures, dimensions, time_dimensions, filters, order, limit)
    try:
        payload = _post("/load", {"query": query})
    except CubeError as exc:
        return (
            f"Cube rejected the query: {exc}\n"
            f"Query sent: {json.dumps(query)}\n"
            "Check member names with describe_semantics, and confirm that every "
            "member belongs to the same view."
        )

    rows = payload.get("data", [])
    if not rows:
        return (
            "Query succeeded but matched no rows. The members and filters were "
            "valid, so widen the date range or relax a filter — do not assume "
            "the metric is zero."
        )
    return _rows_to_tsv(rows, truncated=len(rows) >= query["limit"])


@mcp.tool()
def explain_query(
    measures: list[str] | None = None,
    dimensions: list[str] | None = None,
    time_dimensions: list[dict] | None = None,
    filters: list[dict] | None = None,
    order: dict | None = None,
    limit: int = 100,
) -> str:
    """Show the SQL Cube would run for a query, without executing it.

    Takes exactly the same arguments as run_query. Use it to verify how joins
    and grain were resolved before trusting a surprising number, or to check
    whether a query is being served by a pre-aggregation (the FROM clause will
    reference a pre-aggregation table rather than the source tables).

    This is for explaining and debugging. To get actual numbers, call run_query.
    """
    try:
        problems = _validate(_collect_names(measures, dimensions, time_dimensions, filters))
    except CubeError as exc:
        return str(exc)
    if problems:
        return "Invalid member names:\n  " + "\n  ".join(problems)

    query = _build_query(measures, dimensions, time_dimensions, filters, order, limit)
    try:
        payload = _post("/sql", {"query": query})
    except CubeError as exc:
        return f"Cube could not compile the query: {exc}"

    sql = payload.get("sql", {}).get("sql")
    if not sql:
        return f"Cube returned no SQL for that query: {json.dumps(payload)[:400]}"
    statement, params = (sql[0], sql[1]) if isinstance(sql, list) else (sql, [])
    return f"SQL:\n{statement}\n\nParameters: {params}"


# ---------------------------------------------------------------------------
# Resource and prompt
#
# Tools are model-invoked; a resource is host-attached read-only context, and a
# prompt is a user-invoked template. Exposing the catalogue both ways lets a
# host either attach it up front or let the model fetch it on demand.
# ---------------------------------------------------------------------------


@mcp.resource("cube://semantics")
def semantics_catalogue() -> str:
    """The full Cube semantic catalogue: every view, measure and dimension."""
    try:
        return describe_semantics(view=None)
    except CubeError as exc:
        return str(exc)


@mcp.prompt()
def analyse(question: str) -> str:
    """Answer a business question through the semantic layer, with provenance."""
    return (
        f"Answer this question using the Cube semantic layer: {question}\n\n"
        "Work in this order:\n"
        "1. describe_semantics() for the list of views.\n"
        "2. describe_semantics(view=...) for the one you chose — read the grain "
        "warnings in the descriptions before picking members.\n"
        "3. run_query(...) with fully qualified member names.\n"
        "4. State the answer with the numbers, then name the exact members and "
        "filters you used so the result can be reproduced.\n\n"
        "Do not write SQL. If a member name is rejected, re-read the vocabulary "
        "and retry rather than guessing a variant."
    )


if __name__ == "__main__":
    # stdio transport: the host launches this process and speaks JSON-RPC over
    # stdin/stdout. No ports, no auth, no CORS. Swap to
    # mcp.run(transport="streamable-http") only when something has to reach it
    # over the network.
    log.info("cube-semantics MCP server starting, Cube at %s", CUBE_URL)
    mcp.run()
