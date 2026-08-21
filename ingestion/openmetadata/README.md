# OpenMetadata ingestion configs

Declarative workflows that catalog a source into OpenMetadata — step 1 of the
platform: **understand the source before any load.** Nothing is clicked in the
UI; each workflow is a template here, rendered from `.env` and run inside the
official OpenMetadata *ingestion image* on the compose network (so no heavy
`openmetadata-ingestion` dependency lands in this project's env, and the source
`postgresql:5432` / server `openmetadata-server:8585` are reachable by name).

| Template | Workflow | What it does |
|---|---|---|
| `database_metadata.yaml` | `ingest` | Schemas, tables, columns, types |
| `database_profiler.yaml` | `profile` | Column profiles: row/null/distinct counts, min/max/mean |
| `auto_classification.yaml` | `classify` | Sample rows + auto-applied PII tags (`PII.Sensitive` / `PII.NonSensitive`) |
| `dbt.yaml` | `ingest-dbt` | dbt model descriptions, tests, model lineage (run after `dbt build`) |
| `snowflake_metadata.yaml` | `ingest` | Metadata for a Snowflake source (template) |

`${VAR}` placeholders are filled from `.env`; the runner
(`orchestration/defs/openmetadata/ingest.py`) validates the required ones first,
renders, and runs the container.

## Run

```bash
make up                 # brings up OpenMetadata (+ Postgres, Elasticsearch)
make om-wait            # block until the API answers
make om-token           # mint an admin PAT -> OPENMETADATA_JWT_TOKEN in .env
make om-ingest          # metadata -> profiler -> classify, on OM_SOURCE_SERVICE
```

Or one workflow at a time: `make om-ingest-metadata` / `-profiler` / `-classify`
/ `-dbt`. On the Dagster graph these are the `openmetadata` asset group
(`orchestration/defs/openmetadata/`).

## Point it at your own source

Edit `.env`:

- `OM_SOURCE_SERVICE` — the name the source appears under in OpenMetadata.
- `OM_SCHEMA_INCLUDE` — regex of schema(s) to include, e.g. `^public$`.
- `SOURCE_DB_HOSTPORT` / `SOURCE_DB_DATABASE` / `SOURCE_DB_USERNAME` /
  `SOURCE_DB_PASSWORD` — how the ingestion container reaches the source. For a
  source outside the compose network, use a host-reachable address.

For Snowflake, use `snowflake_metadata.yaml` and set the `SNOWFLAKE_*` vars (see
`.env.example`). The profiler and classify workflows work against any source
type — copy their `sourceConfig` onto the matching `serviceConnection`.

## Verified

Against a live OpenMetadata 1.12.6, on a seeded `demo` source (customers/orders):
metadata, profiler and classify all run to 100% success; `email` was tagged
`PII.Sensitive`, `country`/`created_at` `PII.NonSensitive`.
