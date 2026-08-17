"""Dagster entry point for the platform.

There is deliberately almost nothing here. Every definition lives in a
`defs.yaml` under `orchestration/defs/`, and `load_from_defs_folder` walks that
tree, resolves each component and merges the result into one `Definitions`.
Adding a source or a transformation step means adding a YAML file, not Python.

The `@dg.definitions` decorator makes loading lazy, so importing this module
does not call the Airbyte API or spawn dbt.
"""

from pathlib import Path

import dagster as dg

PROJECT_ROOT = Path(__file__).parent.parent


@dg.definitions
def defs() -> dg.Definitions:
    return dg.load_from_defs_folder(project_root=PROJECT_ROOT)
