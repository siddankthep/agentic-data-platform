"""OpenMetadata ingestion as Dagster assets.

Makes "understand the source" and "catalog the warehouse" first-class assets on
the same graph as Airbyte and dbt, so the catalog refreshes on the same clock as
everything else (Phase 1, step 4). Each asset shells out to the workflow runner in
`ingest.py`, which runs the official OpenMetadata ingestion image on the compose
network — no heavy dependency is added to this project's env.

The dbt-catalog asset is meant to run *after* `dbt build`; wiring an explicit
`deps` on a specific mart asset key is left until a real source's models exist
(the mart keys are per-source). Until then these are a self-contained group you
materialize after a source is connected.
"""

from __future__ import annotations

import dagster as dg

from .ingest import run_workflow

GROUP = "openmetadata"


@dg.asset(group_name=GROUP, description="Catalog the source's schemas, tables and columns into OpenMetadata.")
def openmetadata_source_metadata() -> None:
    run_workflow("metadata")


@dg.asset(
    group_name=GROUP,
    deps=[openmetadata_source_metadata],
    description="Column-level profiles (row/null/distinct counts, min/max/mean) for the catalogued tables.",
)
def openmetadata_profiler() -> None:
    run_workflow("profiler")


@dg.asset(
    group_name=GROUP,
    deps=[openmetadata_source_metadata],
    description="Sample rows + auto-applied PII classifications (PII.Sensitive / PII.NonSensitive).",
)
def openmetadata_auto_classification() -> None:
    run_workflow("classify")


@dg.asset(
    group_name=GROUP,
    description="Attach dbt model descriptions, tests and model lineage to the warehouse tables. Run after `dbt build`.",
)
def openmetadata_dbt_catalog() -> None:
    run_workflow("dbt")


@dg.definitions
def defs() -> dg.Definitions:
    return dg.Definitions(
        assets=[
            openmetadata_source_metadata,
            openmetadata_profiler,
            openmetadata_auto_classification,
            openmetadata_dbt_catalog,
        ]
    )
