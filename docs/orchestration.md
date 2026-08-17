# Orchestration

How Airbyte and dbt become one Dagster asset graph, and what you have to know
to operate it. Read this before touching `orchestration/`.

## Data flow

```
Stripe API
   │  Airbyte connection "Stripe -> Postgres (raw)" (ingestion/terraform/)
   ▼
stripe/<stream>          21 Dagster assets, group `raw_stripe`.
                          Materializing any one triggers a sync of the whole
                          connection — Airbyte's unit of work is the
                          connection, not the stream.
   │  dbt source() resolves to the SAME asset keys
   ▼
staging/stg_stripe__*    ─┐
intermediate/int_stripe__*│  34 Dagster assets + 108 dbt tests as asset checks
marts/{dim,fct}_*        ─┘
   │
   ▼
silver_marts.*           What Cube reads (see stripe-data-model.md).
```

Two YAML files define all of it:

| File | Component | Produces |
|---|---|---|
| `orchestration/defs/airbyte/defs.yaml` | `dagster_airbyte.AirbyteWorkspaceComponent` | 21 raw stream assets |
| `orchestration/defs/dbt/defs.yaml` | `dagster_dbt.DbtProjectComponent` | 34 model assets + 108 checks |

`orchestration/definitions.py` is four lines and exists only to call
`load_from_defs_folder`. Adding a source or a transformation step means adding
YAML, not Python.

## The asset key contract

This is the single thing that makes it one graph rather than two:

- dbt keys a source as `[source_name, table_name]` → `stripe/customers`.
  `stripe` is the source name in `_stripe__sources.yml`.
- Airbyte's default key is just the stream name → `customers`.

So `airbyte/defs.yaml` remaps it:

```yaml
translation:
  key: "stripe/{{ props.stream_name }}"
```

Get this wrong and nothing errors. You get two disconnected islands: Airbyte
assets nobody depends on, and dbt models with upstreams that never materialize.
`make dagster-check` catches it — it fails if any dbt upstream is dangling.

## Automation

There are no schedules or sensors in the usual sense. Both components carry an
`automation_condition`, and the AssetDaemon (started by `dagster dev`) acts on
them:

- **Airbyte assets** — `on_cron('0 6 * * *')`. Dagster owns the clock. The
  connection in `ingestion/terraform/connection.tf` is deliberately `manual`
  so a sync can be triggered from exactly one place.
- **dbt assets** — `eager()`. A model rebuilds when its upstreams actually
  change, rather than on a timer that hopes the sync already finished.

One 6am sync therefore cascades through staging → intermediate → marts on its
own. That is the *data-aware scheduling* idea: the graph reacts to data, not
to the wall clock.

## Commands

| Command | What it does |
|---|---|
| `make dagster-dev` | UI + daemon at localhost:3000. The daemon is what evaluates automation. |
| `make dagster-check` | Static validation: resolves both components, builds the dbt manifest, verifies asset keys line up. Fast; the CI command. |
| `make dagster-refresh` | Re-pull cached component state. **See the caveat below.** |
| `make dagster-dbt` | Materialize dbt only — skips the Airbyte sync, so it neither hits the Stripe API nor waits on a connector pod. |
| `make dagster-materialize` | The whole graph by hand, Airbyte sync included. |

## Operational caveats

- **Cached state is a full copy, and it goes stale.** Both components cache
  state under `orchestration/defs/.local_defs_state/` — the Airbyte connection
  catalog, and for dbt an entire **copy of `transformation/`**. Dagster runs
  dbt against that copy, not against your working tree. Edit a model and the
  orchestrated run still executes the old SQL, and deleted models still appear
  in the graph. Run `make dagster-refresh` after any dbt change. This is the
  single most confusing behaviour here; it cost a debugging cycle to find.

- **`dg check defs` is stricter than `dagster definitions validate`.** The
  latter passed while the dbt component was misconfigured; only `dg check defs`
  actually builds every component. Use `make dagster-check`.

- **dbt-core is pinned `<1.12`** in `pyproject.toml` because `dagster-dbt`
  0.29.x requires it. The two must move together — bumping dbt alone breaks the
  `dagster_dbt` import outright. Integration packages version as `0.(N+16).x`
  against `dagster` `1.N.x`: dagster `1.13.18` ↔ dagster-dbt `0.29.18`.

- **`transformation/profiles.yml` lives in the repo**, not `~/.dbt`, so Dagster
  can run dbt without machine-local state outside the checkout. It reads the
  same `POSTGRES_*` vars from `.env` as everything else, and dbt prefers it over
  `~/.dbt/profiles.yml`, so manual `dbt build` is unaffected.

- **The project is installed editable** (`[build-system]` + `uv sync`). Without
  that, `dg utils refresh-defs-state` fails with `ModuleNotFoundError: No module
  named 'orchestration'` — it resolves definitions in a subprocess that does not
  inherit the repo root on `sys.path`, even though `dagster dev` from the root
  works off the cwd.

- **Airbyte must be reachable at localhost:8000** when definitions load, since
  `AirbyteWorkspaceComponent` pulls the connection catalog from the API. If
  `abctl` is down, refresh the state while it is up and the cached copy keeps
  the graph loadable.
