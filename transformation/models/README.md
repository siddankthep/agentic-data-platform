# dbt models — the contract the generation agent fills

These directories are empty in the scaffold. The generation agent (Phase 4)
writes the medallion pipeline here for the connected source; `make example-stripe`
drops the hand-built Stripe example in, as a reference for what "done" looks like.

## Layout

```
models/
  staging/      stg_*   1:1 with a raw source table. Rename + cast, no joins. Views.
  intermediate/ int_*   Joins, fan-out/fan-in handling. Views/ephemeral.
  marts/        dim_* fct_*   Business grain. Tables. What Cube reads.
```

Materialization and per-layer schema are set once in `dbt_project.yml`, giving
`silver_staging` / `silver_intermediate` / `silver_marts`. Cube reads
`silver_marts`.

## Rules the layers encode

- **Staging reads `raw`, and only `raw`.** `raw.*` exists because Airbyte landed
  it there; nothing models a source directly. Declare the raw tables in a sources
  file — see `_sources.yml.example` — so `source()` resolves and, just as
  importantly, so the Dagster asset keys line up with the Airbyte assets (the key
  contract in `docs/orchestration.md`).
- **Cube points at marts, not staging.** If Cube has to do defensive joins to fix
  grain, modeling was pushed into the wrong layer.
- **Every mart declares its grain and tests it.** A `unique` test on the grain key
  turns a grain mistake into a red `dbt build` instead of a silently wrong number.
- **Descriptions are agent-facing docs.** Column descriptions in the `schema.yml`
  files are ingested by OpenMetadata and become context the analyst agent reads.

Convention (as in the Stripe example): namespace each source's models in a
subfolder per layer — `staging/<source>/stg_<source>__*.sql` — and pair each with
a `_<source>__*.yml`.
