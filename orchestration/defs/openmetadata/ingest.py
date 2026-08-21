"""Run OpenMetadata ingestion workflows from a template + .env.

One code path, two callers: the CLI (`python -m orchestration.defs.openmetadata.ingest metadata`)
and the Dagster assets in `definitions.py`. Each workflow is a YAML template under
`ingestion/openmetadata/` with `${VAR}` placeholders; this module renders them from
the environment and runs them inside the official OpenMetadata *ingestion image* on
the compose network, so no heavy `openmetadata-ingestion` dependency lands in this
project's locked env, and the source (`postgresql:5432`) and server
(`openmetadata-server:8585`) are reachable by their in-network names.

Verified against a live OpenMetadata 1.12.6: metadata, profiler and classify all
run to 100% success on the seeded demo source.
"""

from __future__ import annotations

import os
import string
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
TEMPLATE_DIR = REPO_ROOT / "ingestion" / "openmetadata"

# workflow name -> (template file, `metadata` subcommand)
WORKFLOWS: dict[str, tuple[str, str]] = {
    "metadata": ("database_metadata.yaml", "ingest"),
    "profiler": ("database_profiler.yaml", "profile"),
    "classify": ("auto_classification.yaml", "classify"),
    "snowflake": ("snowflake_metadata.yaml", "ingest"),
    "dbt": ("dbt.yaml", "ingest-dbt"),
}

# Env vars each workflow requires a non-empty value for. Validated before render
# so a missing credential fails loudly rather than shipping a broken config.
_DB = ["OPENMETADATA_HOST_PORT", "OPENMETADATA_JWT_TOKEN", "OM_SOURCE_SERVICE",
       "SOURCE_DB_HOSTPORT", "SOURCE_DB_DATABASE", "SOURCE_DB_USERNAME",
       "SOURCE_DB_PASSWORD", "OM_SCHEMA_INCLUDE"]
REQUIRED: dict[str, list[str]] = {
    "metadata": _DB,
    "profiler": _DB,
    "classify": _DB,
    "snowflake": ["OPENMETADATA_HOST_PORT", "OPENMETADATA_JWT_TOKEN", "OM_SOURCE_SERVICE",
                  "OM_SCHEMA_INCLUDE", "SNOWFLAKE_USERNAME", "SNOWFLAKE_PASSWORD",
                  "SNOWFLAKE_ACCOUNT", "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_DATABASE",
                  "SNOWFLAKE_ROLE"],
    "dbt": ["OPENMETADATA_HOST_PORT", "OPENMETADATA_JWT_TOKEN", "OM_WAREHOUSE_SERVICE"],
}

# Defaults assume the in-network run (the workflow is a container on app_net).
DEFAULTS = {
    "OPENMETADATA_HOST_PORT": "http://openmetadata-server:8585/api",
    "OM_INGESTION_IMAGE": "docker.getcollate.io/openmetadata/ingestion:1.12.6",
    "OM_INGESTION_NETWORK": "agentic-data-platform_app_net",
    "SOURCE_DB_HOSTPORT": "postgresql:5432",
    "SOURCE_DB_DATABASE": "ecom",
    "SOURCE_DB_USERNAME": "cube",
    "OM_SOURCE_SERVICE": "demo_warehouse",
    "OM_WAREHOUSE_SERVICE": "demo_warehouse",
    "OM_SCHEMA_INCLUDE": "^demo$",
}


def _load_dotenv(env: dict[str, str]) -> None:
    """Merge repo-root .env into `env` without overriding already-set keys."""
    dotenv = REPO_ROOT / ".env"
    if not dotenv.exists():
        return
    for line in dotenv.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        env.setdefault(key.strip(), val.strip())


def _resolved_env() -> dict[str, str]:
    env = dict(os.environ)
    _load_dotenv(env)
    for key, val in DEFAULTS.items():
        env.setdefault(key, val)
    return env


def render(workflow: str, env: dict[str, str] | None = None) -> str:
    """Render a workflow template, substituting ${VAR} from the environment.

    Required vars are validated first so a missing credential fails with a clear
    message. `safe_substitute` is used so literal `$` in template comments does
    not break rendering.
    """
    if workflow not in WORKFLOWS:
        raise ValueError(f"unknown workflow {workflow!r}; choose from {sorted(WORKFLOWS)}")
    env = env or _resolved_env()
    missing = [k for k in REQUIRED.get(workflow, []) if not env.get(k)]
    if missing:
        raise SystemExit(
            f"missing environment values for {workflow!r}: {', '.join(missing)}. "
            "Set them in .env (see ingestion/openmetadata/README.md)."
        )
    template_text = (TEMPLATE_DIR / WORKFLOWS[workflow][0]).read_text()
    return string.Template(template_text).safe_substitute(env)


def run_workflow(workflow: str, env: dict[str, str] | None = None) -> None:
    """Render `workflow` and run it in the OpenMetadata ingestion image."""
    env = env or _resolved_env()
    subcommand = WORKFLOWS[workflow][1]
    rendered = render(workflow, env)

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
        fh.write(rendered)
        config_path = fh.name
    # NamedTemporaryFile is 0600; the ingestion container runs as a different uid
    # and must be able to read the bind-mounted config.
    os.chmod(config_path, 0o644)

    cmd = [
        "docker", "run", "--rm",
        "--network", env["OM_INGESTION_NETWORK"],
        "--entrypoint", "metadata",
        "-v", f"{config_path}:/ingestion.yaml:ro",
    ]
    # dbt ingestion reads the local dbt artifacts; mount them read-only.
    if workflow == "dbt":
        cmd += ["-v", f"{REPO_ROOT / 'transformation' / 'target'}:/dbt:ro"]
    cmd += [env["OM_INGESTION_IMAGE"], subcommand, "-c", "/ingestion.yaml"]

    print(f"[openmetadata] running '{workflow}' ({subcommand}) ...", flush=True)
    try:
        subprocess.run(cmd, check=True)
    finally:
        os.unlink(config_path)


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if not argv or argv[0] in {"-h", "--help"}:
        print(f"usage: python -m orchestration.defs.openmetadata.ingest <{'|'.join(WORKFLOWS)}>")
        return 0 if argv else 2
    run_workflow(argv[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
