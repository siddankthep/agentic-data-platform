# Agentic Data Platform

A **plug-and-play scaffold** that lets a terminal agent (built on
[pi](https://pi.dev)) stand up a complete data platform on *any* source you
already have. Point it at your data, and the agent profiles and documents the
source, ingests it into a warehouse you choose, and builds the transformation,
semantic and orchestration layers for a use case you state in one sentence — so
it always works from governed metadata and a semantic layer, never raw SQL
against tables it half-understands.

The stack: ingest with **Airbyte**, transform with **dbt**, orchestrate with
**Dagster**, serve with **Cube**, catalog and govern with **OpenMetadata**, and
drive the whole thing from a **pi** agent.

## The workflow, from your side

Three steps, each handing context to the next:

1. **Connect your source.** Point OpenMetadata at whatever you have — Postgres,
   Snowflake, anything with a connector. It profiles the source, and the agent
   reads that metadata to produce the *governed context*: a glossary, tags and
   classifications, semantic hints, and a Markdown brief documenting every table,
   column and use case. Everything needed to understand the source before a byte
   is moved.
2. **Choose a destination.** Pick the warehouse that will hold the transformed
   data. Airbyte — declared in Terraform, not clicked together in a UI — ingests
   the source into it as a `raw` layer.
3. **State a use case.** Hand the agent one sentence of business intent. It writes
   the dbt models (`raw` bronze → gold marts), the Cube cubes and views that serve
   the use case, and the Dagster wiring that orchestrates the graph.

The end product is a fully-functioning data platform the agent spun up, carrying
the metadata that gives the agent correct context about its own inputs and
outputs.

## Architecture

```
   YOUR source ──①──► OpenMetadata  (understand: profile, glossary, tags, brief)
        │
        └────────②──► Airbyte (Terraform) ──► Destination warehouse: raw.*
                                                      │
                                              ③ dbt ──┴──► marts.*  ──► Cube (semantic)
                                                              │
                                                          Dagster (one asset graph)
```

See [docs/agentic-platform-project.md](docs/agentic-platform-project.md) for the
full concepts and the build plan.

## The three agent roles

One pi agent plays three roles, matching the three steps:

- **Curation agent** — reads a connected source and writes the brief, glossary,
  tags and classifications. *(Understand the source.)*
- **Generation agent** — takes the governed context + a one-sentence use case and
  builds the dbt / Cube / Dagster pipeline. *(Build the platform.)*
- **Analyst agent** — the read path: discover → understand semantics → query
  safely → explain provenance → repair staleness. *(Prove it works.)*

## What's in the box

| Layer | Tool | State |
|---|---|---|
| Warehouse | Postgres (Docker Compose) | ✅ running |
| Ingestion | Airbyte via `abctl` + Terraform | ✅ (Stripe example) |
| Transform | dbt (`transformation/`) | ✅ (Stripe example) |
| Semantics | Cube (`cube_semantics/`) + MCP server | ✅ (Stripe example) |
| Orchestration | Dagster (`orchestration/`) | ✅ Airbyte + dbt in one graph |
| Catalog | OpenMetadata (Docker Compose) | 🟡 base services only |
| Agents | pi (curation / generation / analyst) | ⛔ planned |

A complete, hand-built **Stripe** pipeline ships as a *worked example* — the
reference the agents' output is scored against. It lives (after Phase 0) under
`examples/` and can be deleted to leave a clean, source-agnostic scaffold. It is
**not** the product; it is what "done" looks like.

## Quickstart

**Prerequisites:** Docker + Docker Compose, `uv`, Go (for the `migrate` CLI),
and ~16–32 GB RAM (the full stack — Airbyte's kind cluster, OpenMetadata,
Dagster, Cube, Postgres — is heavy; run layers in isolation if constrained).

```bash
make init          # install migrate + pi, copy .env.example -> .env
make up            # start Postgres, Cube, OpenMetadata
make migrate-up    # provision schemas
make sync          # land the example source into raw via Airbyte (Terraform)
make dagster-dev   # open the unified asset graph at localhost:3000
```

Key endpoints: Cube playground `:4000`, OpenMetadata `:8585`, Dagster `:3000`,
Postgres `:5435` (host).

Run `make` targets `down`, `reset`, `psql`, `dagster-check`, and the Airbyte/
Terraform targets (`tf-plan`, `tf-apply`, `sync`) as needed — see the
[Makefile](Makefile) and [ingestion/Makefile](ingestion/Makefile).

## Where to go next

- [docs/agentic-platform-project.md](docs/agentic-platform-project.md) — the
  concepts, the tool-by-tool reasoning, and the phased build plan. **Start here.**
- [docs/orchestration.md](docs/orchestration.md) — how Airbyte and dbt become one
  Dagster asset graph.
- [docs/mcp-cube-guide.md](docs/mcp-cube-guide.md) — building the Cube MCP server.
- [examples/stripe/README.md](examples/stripe/README.md) — the Stripe worked
  example, and how to install/remove it. Its
  [docs/](examples/stripe/docs/) hold the Stripe data model and example queries.

## Roadmap

The build plan to turn this from a Stripe-shaped repo into a source-agnostic,
plug-and-play scaffold (full detail in §9 of the project doc):

- **Phase 0** — Genericize: extract the Stripe pipeline into a removable
  `examples/`, leave documented template directories, parameterize source and
  destination.
- **Phase 1** — OpenMetadata: connect and profile any source; wire connectors,
  the MCP server, and a scoped bot.
- **Phase 2** — Curation agent: source → glossary, tags, and the Markdown brief.
- **Phase 3** — Ingestion: parameterized Airbyte/Terraform, source → chosen
  warehouse.
- **Phase 4** — Generation agent: use case → dbt + Cube + Dagster, with a
  build-verify loop.
- **Phase 5** — Analyst agent: the read path, and the acceptance test for the
  other two.
- **Phase 6** — Plug-and-play polish: one command from cold on a new source.

## License

See [LICENSE](LICENSE).
