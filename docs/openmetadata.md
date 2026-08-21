# OpenMetadata — understand any source (Phase 1)

How the platform connects to a source, profiles it, and exposes the result as
governed context — the substrate the curation agent (Phase 2) reads. Read this
before touching `ingestion/openmetadata/` or `orchestration/defs/openmetadata/`.

## What runs where

- **The catalog** — `openmetadata-server`, `elasticsearch` and the OM schema in
  Postgres, all in `docker-compose.yml`. `make up` starts them.
- **Ingestion workflows** — declarative YAML in `ingestion/openmetadata/`, run
  inside the official OpenMetadata *ingestion image* on the compose network by
  the runner in `orchestration/defs/openmetadata/ingest.py`. No
  `openmetadata-ingestion` dependency is added to this project's locked env.
- **On the Dagster graph** — the same workflows are the `openmetadata` asset
  group (`orchestration/defs/openmetadata/definitions.py`), so the catalog
  refreshes alongside Airbyte and dbt.

```
your source ──(ingestion image on app_net)──► OpenMetadata
   metadata   : schemas, tables, columns, types
   profiler   : row/null/distinct counts, min/max/mean
   classify   : sample rows + PII tags (PII.Sensitive / PII.NonSensitive)
   dbt        : model descriptions, tests, lineage (after dbt build)
```

## First run (against the seeded demo source)

`make up` seeds nothing by itself; the walkthrough below profiles a small `demo`
schema so the mechanics are visible end to end. Point `.env` at your own source
to catalog that instead.

```bash
make up                 # Postgres + Elasticsearch + OpenMetadata
make om-wait            # block until the OM API answers
make om-token           # mint an admin PAT -> OPENMETADATA_JWT_TOKEN in .env
make om-bot             # scoped curation-agent bot -> OM_STEWARD_BOT_TOKEN in .env
make om-ingest          # metadata -> profiler -> classify on OM_SOURCE_SERVICE
```

Then browse the catalog at http://localhost:8585 (admin@open-metadata.org /
admin), or query the API — e.g. tables under the service, or a column's PII tag.

## Authentication

- **Admin login** is basic auth (`admin@open-metadata.org` / `admin`; override
  with `OM_ADMIN_EMAIL` / `OM_ADMIN_PASSWORD`).
- **`make om-token`** mints a long-lived Personal Access Token and writes
  `OPENMETADATA_JWT_TOKEN` — what the ingestion workflows authenticate with.
- **`make om-bot`** creates a **scoped** bot for the Phase 2 curation agent:
  a `data-steward-policy` (read tables/schemas; edit glossary, tags,
  descriptions), a `data-steward-role`, and the `data-steward-bot`. Its token
  (`OM_STEWARD_BOT_TOKEN`) is **not** the ingestion bot's — OpenMetadata tokens
  inherit their creator's permissions, so the write agent gets its own bounded
  scope. `scripts/openmetadata.sh` is idempotent (it rotates the bot token each
  run).

## MCP server

OpenMetadata 1.12 ships an MCP server (the `McpApplication`, enabled by default)
at `POST http://localhost:8585/mcp` (streamable HTTP). It exposes search,
lineage and glossary tools to any MCP client, authenticated with a bearer token
that inherits the caller's RBAC. Verified with an `initialize` handshake
(`openmetadata-mcp-stateless`). Phase 5's analyst agent reads through it; Phase 2
writes through the REST API (the MCP surface is read-shaped).

## dbt ingestion

`make om-ingest-dbt` attaches dbt model descriptions, tests and model lineage to
the warehouse tables, reading `transformation/target/` (mounted into the image).
Run it after the warehouse tables are catalogued and after a `dbt build`, so the
artifacts exist and their target tables are already entities.

## Point it at your own source

Set in `.env`: `OM_SOURCE_SERVICE`, `OM_SCHEMA_INCLUDE`, and the `SOURCE_DB_*`
connection (or `SNOWFLAKE_*` with `snowflake_metadata.yaml`). See
`ingestion/openmetadata/README.md` for the full matrix.

## Verified end to end

On a live OpenMetadata 1.12.6 with a seeded `demo` source (`customers`,
`orders`):

- metadata → both tables with columns and types catalogued;
- profiler → `orders` rowCount 1000, column metrics stored;
- classify → `email` tagged `PII.Sensitive`, `country`/`created_at`
  `PII.NonSensitive`;
- scoped bot token authenticates; MCP `initialize` succeeds;
- the four `openmetadata` Dagster assets resolve.

## Operational notes

- **`dagster dev` / `make dagster-check` still require Airbyte reachable** at
  `localhost:8000` (the `AirbyteWorkspaceComponent` pulls its catalog at load
  time — see `docs/orchestration.md`). The OpenMetadata assets themselves have no
  load-time dependency; they invoke `docker` only when materialized.
- **Sample-data rows** may not populate on every setup even when `classify`
  succeeds; the profiles and PII tags are the load-bearing outputs.
- The ingestion image runs as a non-root uid, so the runner makes its rendered
  config world-readable before bind-mounting it.
