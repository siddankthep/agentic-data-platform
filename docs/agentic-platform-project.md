# The Agentic Data Platform: concepts, tools, and a build plan

A guiding doc for the full project: ingest with **Airbyte**, transform with
**dbt**, orchestrate with **Dagster**, serve with **Cube**, catalog/govern with
**OpenMetadata**, and drive the whole thing from a custom agent built on
**pi**.

This doc is written to be read once end-to-end before you write code, then used
as a reference per phase. It answers, for each tool: what problem it solves,
what it would look like if you *didn't* have it, the mental model, and exactly
where it plugs into the other pieces.

---

## 0. What you're actually building

### The one-sentence version

A local, reproducible data platform over the Olist e-commerce dataset where a
terminal agent can answer *"why did average delivery time in São Paulo spike in
Q3, and which sellers drove it?"* — and the agent gets the answer by using
governed metadata and a semantic layer, not by writing raw SQL against tables it
half-understands.

### The architecture

```
                          ┌───────────────────────────────────────┐
                          │      pi agent  (your harness)         │
                          │  tools: catalog / semantics / query   │
                          │         lineage / run-pipeline        │
                          └───┬──────────┬───────────┬────────────┘
                     MCP      │          │ MCP       │ MCP / HTTP
              ┌───────────────┘          │           └──────────────┐
              ▼                          ▼                          ▼
      ┌───────────────┐          ┌──────────────┐          ┌────────────────┐
      │ OpenMetadata  │          │     Cube     │          │    Dagster     │
      │ catalog +     │          │ semantic     │          │ orchestration  │
      │ glossary +    │          │ layer        │          │ + asset graph  │
      │ lineage +     │          │ (measures,   │          │                │
      │ ontology/KG   │          │  dimensions) │          │                │
      └───────▲───────┘          └──────▲───────┘          └───┬────────┬───┘
              │ metadata ingestion      │ SQL                  │        │
              │                         │                      │        │
      ┌───────┴─────────────────────────┴──────────────────────▼──┐     │
      │                     Postgres  (warehouse)                 │     │
      │   raw.*  (Airbyte lands here)   →   marts.*  (dbt builds) │     │
      └───────────────────────────▲───────────────────────────────┘     │
                                  │                                     │
                          ┌───────┴────────┐                            │
                          │    Airbyte     │◄───────────────────────────┘
                          │  EL: sources → raw                triggered by
                          └───────▲────────┘                    Dagster
                                  │
                   ┌──────────────┴───────────────┐
                   │  CSV files / Postgres source │
                   │  / Faker / a real SaaS API   │
                   └──────────────────────────────┘
```

### The end product — be concrete

When you're done you should be able to run:

```bash
pi --agent data-platform
> Which product categories have the worst review scores relative to their
  delivery time, and is the data trustworthy?
```

and watch the agent do roughly this:

1. `search_catalog("reviews")` → OpenMetadata returns `marts.fct_order_reviews`,
   its owner, description, freshness, and the glossary term *Review Score*.
2. `describe_semantics()` → Cube returns the `order_reviews` cube with measures
   `avg_score`, `count`, joined to `orders.delivery_days` and
   `products.category_en`.
3. `run_query({measures, dimensions, filters})` → Cube compiles to SQL, hits
   Postgres, returns rows. No hallucinated join keys, because joins are declared
   in the semantic layer, not invented by the model.
4. `get_lineage("marts.fct_order_reviews")` → the agent can say *"this comes
   from `raw.olist_order_reviews_dataset`, last synced 3 h ago by Airbyte
   connection X, transformed by dbt model Y"*.
5. `check_freshness()` / `trigger_pipeline()` → if the data is stale, the agent
   asks Dagster to materialize the affected assets, then re-answers.

That loop — **discover → understand semantics → query safely → explain
provenance → repair staleness** — is the *read* path. It is the easiest of the
three deliverables and the least interesting one, because the agent only
consumes context that a human already curated.

### The two agent roles — the actual end goal

The deliverable this project is judged on is the **write** path: an agent that
*produces* the governed context, not one that merely reads it. Two roles, in
order:

**1. The curation agent — replaces the Data Steward.** Given (a) a domain's
technical metadata already ingested into OpenMetadata and (b) a Markdown brief
describing the tables, columns and use cases in business prose, the agent
creates the glossary, terms, classifications, domain and asset links inside
OpenMetadata. The semantic layer stops being hand-maintained documentation and
becomes an artifact an agent curates and keeps in sync. → **Phase 5**

**2. The generation agent — replaces the Data Engineer.** Given (a) that
governed semantic metadata and (b) a use-case goal in one sentence, the agent
generates the medallion pipeline that answers it: dbt staging → intermediate →
marts, Cube cubes and a consumer-facing view, and the Dagster wiring — with
minimal human interaction and a build-verify loop that proves the output is
correct rather than merely plausible. → **Phase 6**

The read loop above then becomes the **acceptance test** for both: if an analyst
agent can answer a business question through metadata and marts that no human
wrote, the two roles were genuinely automated. → **Phase 7**

The pipelines underneath are the substrate that makes all three possible.

Note the deliberate asymmetry already sitting in this repo, because it is what
makes the demo measurable: **Stripe is modeled by hand** (21 staging models, 11
marts, 11 cubes, 2 views, written by a human with grain warnings and prose
descriptions). **Olist is nine raw tables in the same warehouse with no dbt
models, no cubes and no glossary.** Stripe is the golden reference; Olist is the
greenfield the agent builds. Same warehouse, same tooling, same reviewer — one
built by a person, one by an agent, scored against each other.

### Why this is a good learning project

Every layer teaches a distinct concept that generalizes:

| Layer | Concept you actually learn |
|---|---|
| Airbyte | ELT vs ETL, incremental sync, state/cursors, schema drift, connector protocols |
| dbt | Declarative transformation, DAG from `ref()`, testing, medallion modeling |
| Dagster | Software-defined assets, data-aware scheduling, cross-tool DAG unification |
| Cube | Semantic layer, measures vs dimensions, pre-aggregations, the "one metric definition" problem |
| OpenMetadata | Metadata as a graph, ontology/RDF, glossaries, lineage, governance |
| pi | Agent harness internals: tools, context engineering, error-driven self-correction |

---

## 1. The core concept tying it all together: the context problem

Before the tools, the thesis.

An LLM pointed at a raw warehouse fails in a predictable way. Given
`olist_orders_dataset`, it will:

- guess that `order_purchase_timestamp` is "the" order date (there are five date
  columns and the right one depends on the question),
- invent a join to `order_items` on `order_id` and then double-count revenue
  because the grain changed,
- compute "delivery time" three different ways across three conversations,
- have no idea the table was last refreshed six weeks ago.

None of these are model-intelligence problems. They're **context problems**.
The fix is to give the agent two different kinds of context:

**Semantic context — "what does this mean, and how do I compute it correctly?"**
That's Cube. A measure `revenue` is defined *once*, with its grain and joins,
and the agent can only ask for it by name. Correctness by construction.

**Organizational context — "what exists, who owns it, where did it come from,
can I trust it?"** That's OpenMetadata. Discovery, lineage, ownership,
freshness, glossary terms, classifications (PII), quality test results.

Cube stops the agent from computing the wrong number. OpenMetadata stops it
from using the wrong table, or a right table with stale data. You need both, and
they're genuinely different problems — this is the single most important idea in
the whole project.

The pipeline tools (Airbyte, dbt, Dagster) exist to produce the data those two
layers describe, and — just as importantly — to **emit the metadata** that makes
the context real rather than hand-written and rotting.

---

## 2. Airbyte — ingestion (the EL of ELT)

### The problem it solves

You need data from N sources in your warehouse. Written by hand, each source is:
auth + pagination + rate limits + incremental cursor state + schema drift +
retries + normalization + backfill. That's ~500 lines of fiddly code per source
that breaks whenever the vendor changes an API, and it is *identical work*
across every company on earth. Airbyte is the commoditization of that work:
600+ connectors behind one protocol.

### The mental model

Airbyte is not a transformation tool. It is a **byte mover with memory**.

```
Source connector ──► Airbyte Protocol (AirbyteMessage stream) ──► Destination connector
    (spec/check/                   RECORD / STATE / LOG /              (writes raw
     discover/read)                 TRACE / CATALOG                     + _airbyte_* cols)
```

Four things define a connector, and they map exactly onto four CLI commands
every connector implements:

- **`spec`** — what config do I need? (renders the UI form)
- **`check`** — can I connect with this config?
- **`discover`** — what streams/fields exist? (produces the *catalog*)
- **`read`** — emit RECORD messages, and periodically a STATE message

**STATE is the concept worth internalizing.** The destination acknowledges
records; Airbyte persists the last STATE it saw. On the next sync, the source is
handed that state back and resumes from the cursor. This is why incremental sync
survives crashes: it's checkpointing, not "remember the max timestamp."

**Sync modes** (per stream, chosen at connection setup):

| Mode | Behavior | Use when |
|---|---|---|
| Full refresh / overwrite | Re-read everything, replace | Small dim tables, no reliable cursor |
| Full refresh / append | Re-read everything, append with timestamp | You want snapshots/history |
| Incremental / append | Only rows past cursor, append | Immutable event data |
| Incremental / append + dedup | Append, then dedup on primary key | Mutable records — the common default |

**Deliberate design choice: Airbyte only does E and L.** It lands data in a
`raw` schema, near-verbatim, with `_airbyte_raw_id`, `_airbyte_extracted_at`,
`_airbyte_meta` columns. That's the ELT bet: load first (cheap storage, full
fidelity, replayable), transform in the warehouse with SQL (dbt) where you have
compute, version control, and tests. ETL — transforming in flight — means a
logic bug loses data you can never recover. ELT means you re-run dbt.

### Where it fits here

Your repo currently seeds Postgres from CSVs via `db/seed.sql`. That's fine for
Cube practice, but it teaches you nothing about ingestion and it's not
re-runnable in an interesting way. Replace it with:

- **`source-postgres`** reading from a `seed` schema (or a separate "operational
  DB" container) → **`destination-postgres`** into `raw`. This gives you real
  CDC/incremental practice with zero API keys.
- Then add one genuinely external source — `source-faker` (deterministic, no
  auth) for a synthetic `web_events` stream, so you have a second source system
  and can practice conformed dimensions in dbt.
- Optional stretch: build a **custom connector** with the low-code CDK for some
  small public API. This is where you truly learn the protocol.

### Deployment

**Decided: the full platform via `abctl local install`, configured with
Terraform.** The project ran on PyAirbyte first — the library that executes
connectors in-process with no platform — and that was the right way to get an
end-to-end pipeline working in a day. It stopped being the right answer once
Stripe was the source.

The failure mode was typing. PyAirbyte loads through pandas, and Stripe's schema
defeats it in two specific ways: fields declared as multi-type unions
(`invoice_line_items.plan` is `["null","object","string"]`) fall back to a text
column while the value is still a dict, and `read_json`'s date heuristic coerces
epoch-int columns like `charges.created` into timestamps against a BIGINT
column. Both surfaced as psycopg2 errors, and both had to be fixed by
monkeypatching PyAirbyte's private internals — `_get_airbyte_type` and the
Postgres writer's `pd.read_json` — which pinned the project to unversioned
implementation details.

The platform's destination connectors are typed Java, with no pandas in the load
path, and get both cases right unprompted: those columns land as `jsonb` and
`bigint` respectively. Deleting ~80 lines of patches was the whole argument.

What the platform adds beyond that: real STATE management per stream, a UI for
inspecting failed syncs, and connection-level schema-drift handling. What it
costs: ~8 GB of RAM for the kind cluster.

Configuration lives in `ingestion/terraform/`, not the UI — see `ingestion/terraform/README.md`. The
UI is for *reading* state (job history, logs, catalog); every source,
destination and connection is declared in HCL so the pipeline is reviewable and
reproducible. Getting stuck on Kubernetes in week one is still the most common
way this project dies, which is why `abctl` does the cluster and Terraform only
talks to the API on top of it.

---

## 3. dbt — transformation

You have decent knowledge here, so this section is short and focused on the
*interfaces to the rest of the platform* rather than dbt basics.

### The one idea

dbt turns SQL `SELECT` statements into a dependency graph. `ref('stg_orders')`
does two things: it resolves to a schema-qualified name, and it declares an
edge. The DAG is *derived*, never maintained by hand — which is why it never
lies.

### Layering for this project

```
raw.*                       Airbyte's landing zone. Never queried directly by BI.
  └─► staging/  stg_*       1:1 with source. Rename, cast, no joins. Views.
        └─► intermediate/   int_*  Joins, fan-out/fan-in handling. Ephemeral/views.
              └─► marts/    dim_*  fct_*  Business grain. Tables. What Cube reads.
```

The rule that matters: **Cube should point at marts, not staging.** The semantic
layer expresses business meaning over already-conformed, correct-grain tables.
If Cube has to do defensive joins to fix grain, you've pushed modeling into the
wrong layer.

For Olist specifically the interesting modeling problems are:

- `fct_order_items` at item grain vs `fct_orders` at order grain — revenue
  measured at the wrong grain is the classic fan-out bug, and it's exactly what
  Cube's `join` cardinality declarations protect against downstream.
- `dim_products` needs the `product_category_name_translation` lookup — a real
  conformed-dimension exercise.
- Delivery time = `order_delivered_customer_date - order_purchase_timestamp`,
  with the estimate-vs-actual variance. Define it **once**, in a mart, and let
  Cube expose it as a measure. This is the concrete instance of "one metric
  definition."

### The three integration points you must not skip

1. **Tests** (`not_null`, `unique`, `relationships`, plus `dbt_utils`
   singular tests). These aren't hygiene here — their *results* flow into
   OpenMetadata as data-quality signals, which is how your agent answers "is
   this trustworthy?"
2. **Descriptions in `schema.yml`.** OpenMetadata ingests them. Every column
   description you write is context your agent gets for free. Treat the yml as
   agent-facing documentation.
3. **`target/manifest.json` + `run_results.json`.** These are how both Dagster
   (asset graph) and OpenMetadata (lineage, test results) understand your
   project. Everything downstream reads these two files.

### `dbt-core` vs the dbt Fusion engine

dbt Core (Python, Jinja+SQL) is what you want here — it's what Dagster and
OpenMetadata integrate with most cleanly. The newer Rust-based Fusion engine is
worth knowing exists (faster, real SQL comprehension via static analysis) but
don't take that dependency on a learning project.

---

## 4. Dagster — orchestration

You know Dagster, so again: the framing that matters for *this* build.

### Why an orchestrator at all, and why this one

Airbyte can schedule itself. dbt has `dbt build`. Why add a layer?

Because your pipeline crosses tool boundaries, and correctness lives in the
*seams*: dbt must not run before the Airbyte sync it depends on; Cube's
pre-aggregations must refresh after dbt; OpenMetadata's ingestion should run
after everything; and when `fct_orders` is wrong, you need to know what to
re-run without re-running the world.

Dagster's differentiator is that it models **assets, not tasks**. Airflow asks
"what operations run in what order?" Dagster asks "what data objects exist and
what produces them?" That's the same shift dbt made, generalized across tools —
and it's the right abstraction here because your agent's questions are about
*data* ("is `fct_orders` fresh?"), not about *jobs*.

### The asset graph you'll build

```
@asset (airbyte)          @asset (dbt, auto-generated)         @asset (python)
raw/olist_orders  ──────► stg_orders ──► int_… ──► fct_orders ──► cube_preagg_refresh
raw/olist_items   ──────► stg_items  ──┘                      └─► openmetadata_ingest
raw/web_events    ──────► stg_events ──► fct_sessions ─────────┘
```

Key mechanics to use, each teaching something:

- **`@dbt_assets` with `DagsterDbtTranslator`** — parses `manifest.json` and
  turns every dbt model into a Dagster asset automatically. The lesson: don't
  duplicate a DAG that already exists; import it.
- **`build_airbyte_assets` / `AirbyteResource`** (or a plain `@asset` wrapping
  PyAirbyte) — makes the Airbyte streams first-class assets so dbt models can
  declare them as dependencies. This is the seam that makes the whole graph one
  graph.
- **`AutomationCondition.eager()`** — declarative automation. Instead of cron on
  every step, say "materialize when upstream changes." This is *data-aware
  scheduling*, the concept worth taking to work with you.
- **`AssetCheckSpec` / freshness checks** — Dagster surfaces "is this asset
  fresh and passing checks?" over an API. That becomes a **tool your agent
  calls**.
- **Partitions** (`DailyPartitionsDefinition` on the fact tables) — so a
  backfill of one month doesn't rebuild history.

### Dagster as an agent surface

Explicitly design for this: the agent needs `check_freshness(asset)` and
`materialize(assets)`. Dagster's GraphQL API gives you both. When the agent
finds stale data, it can *fix* it — that's the difference between an analytics
chatbot and an actual agent.

---

## 5. Cube — the semantic layer

You've started here, and `cube_semantics/model/` already has cubes and a view.
This section explains *why* what you've built matters and how to finish it.

### The problem

Ask five people for "revenue" and you get five SQL queries. Ask an LLM twice and
you get two. The semantic layer's job: **define metrics once, in a place that
compiles to SQL, so every consumer gets the same number.**

### The mental model

Cube sits between the warehouse and consumers and speaks a *metric API* instead
of SQL:

```
consumer asks: { measures: ["orders.count"],
                 dimensions: ["products.category_en"],
                 timeDimensions: [{ dimension: "orders.created_at",
                                    granularity: "month" }],
                 filters: [...] }
         │
         ▼
Cube: resolve members → pick join path → check pre-aggregations
      → generate SQL → execute → cache → return typed rows
```

The primitives:

- **Cube** — a logical entity over a table/SQL (`orders`, `products`).
- **Measure** — an aggregation (`count`, `sum(price)`, `avg(review_score)`).
  Measures carry their aggregation *type*, which is why Cube can prevent
  averaging an average.
- **Dimension** — an attribute to group/filter by.
- **Join** — declared with **cardinality** (`one_to_many` etc.). Cube uses this
  to pick a join path and to avoid fan-out double counting.
- **Segment** — a named, reusable filter.
- **View** — a curated, consumer-facing bundle of members from several cubes.
  Your `order_economics.yml` is one. **Views are what you should expose to the
  agent**, not raw cubes: they're the governed, intentional surface, with
  irrelevant internals hidden.
- **Pre-aggregation** — a materialized rollup Cube maintains and transparently
  routes queries to. This is the performance story, and the reason Cube isn't
  just "a YAML wrapper around SQL."

### Why it's exactly right for agents

Three reasons, in order of importance:

1. **The query surface is closed.** The agent can only reference members that
   exist. An invalid member returns a *listable* error ("Unknown measure X;
   available: …") — the model self-corrects in one turn. Compare to raw SQL,
   where a wrong-but-valid query returns a wrong-but-plausible number and
   nobody notices.
2. **Joins and grain are pre-solved.** The single hardest thing for an LLM
   writing warehouse SQL is grain management. Cube removes the decision.
3. **Metadata is machine-readable.** `/v1/meta` returns every cube, member,
   type, title, and description as JSON — a perfect tool schema. Descriptions
   in your YAML are literally prompt engineering.

Cube also ships a **`/v1/sql` endpoint and a SQL API (Postgres wire protocol)**
so tools that insist on SQL can still go through the semantic layer. And Cube
has its own MCP/AI-API work — worth reading, but building your own MCP server
(as `docs/mcp-cube-guide.md` already walks through) teaches you more.

### What to finish

- Add measures for the delivery-time and review metrics; make them descriptive.
- Add at least one pre-aggregation and watch the query plan route to it.
- Extend `order_economics` view, and add a second view for a different persona
  (e.g. `seller_performance`). Two views make the "curated surface" idea click.
- Make every `title:` and `description:` field agent-quality prose.

---

## 6. OpenMetadata — catalog, governance, ontology

This is the piece that's new to you and the most conceptually interesting, so
it gets the most space.

### The problem

Cube tells you how to compute things you already know about. It cannot tell you:
what else exists, who owns it, whether it's fresh, whether it contains PII,
where it came from, what "Active Customer" means to the business, or what broke
when a column was dropped. That's the catalog's job.

Historically catalogs were passive documentation nobody read. OpenMetadata's
current positioning is explicitly different: it calls itself a **context layer**
— *"AI does not need another raw database connector. AI needs context +
memory."* It is built to be consumed by agents, not just browsed by humans.

### The mental model

Everything is an **Entity** with a JSON Schema, a stable ID, a fully-qualified
name, and typed **relationships** to other entities. Entities include: Table,
Column, Dashboard, Pipeline, MLModel, Topic, GlossaryTerm, Domain, DataProduct,
User, Team, TestCase, Metric.

```
                    ┌──────────────┐
                    │  Glossary    │  business language
                    │  Term        │  "Net Revenue", "Active Seller"
                    └──────▲───────┘
                           │ describedBy / tagged
┌────────┐  contains  ┌────┴─────┐  upstream  ┌──────────┐  owned by  ┌──────┐
│ Schema │───────────►│  Table   │◄───────────│ Pipeline │───────────►│ Team │
└────────┘            └────┬─────┘            └──────────┘            └──────┘
                           │ has
                      ┌────▼─────┐  classified  ┌───────────────┐
                      │  Column  │─────────────►│ Classification│  PII.Sensitive
                      └──────────┘              └───────────────┘
```

Five capabilities you'll actually use:

**1. Connectors + ingestion.** 130+ connectors. You'll run the Postgres
connector (tables, schemas, profiles, sample data), the **dbt ingestion**
(descriptions, tests, model-level lineage from `manifest.json`), the **Airbyte
connector** (connection → source/destination lineage), and the **Dagster**
connector. Metadata ingestion runs as a scheduled workflow — which you'll drive
from Dagster, making metadata itself an asset.

**2. Column-level lineage.** Not just "table A feeds table B" but "`fct_orders.
delivery_days` derives from `raw.orders.order_delivered_customer_date` minus
`order_purchase_timestamp`." It's parsed from query logs and dbt manifests. This
is what powers the agent's "where did this come from?" answer, and human impact
analysis before you drop a column.

**3. Glossary + classification.** A Glossary is a controlled vocabulary with
hierarchy, synonyms, and term↔asset links. Define *Delivery SLA* once, link it
to the columns implementing it, and now "SLA" in a user question resolves to a
specific column. Classifications (`PII.Sensitive`) can be auto-applied by the
profiler and enforced by policies — the mechanism by which your agent can be
prevented from returning customer emails.

**4. Ontology / RDF / Knowledge Graph — the new part.**
OpenMetadata publishes its schemas not just as JSON Schema but as a **semantic
web stack**:

- **OWL ontology** (Turtle) — formal class and property definitions: `Table`,
  `Dashboard`, `hasColumn`, with domain/range restrictions and hierarchies.
- **JSON-LD contexts** — map plain JSON metadata onto RDF URIs, so every entity
  is also a set of triples.
- **SHACL shapes** — validation constraints (cardinality, types, value ranges)
  enforced *at the metadata layer*, so bad metadata is rejected on write rather
  than discovered downstream.
- **SPARQL endpoint** — query the metadata graph by meaning and traverse
  arbitrary-depth relationships.
- **Knowledge Graph** (shipped in 1.13) — technical metadata unified with
  semantic metadata (glossary terms, classifications, domains) in one navigable
  graph.
- Alignment with **DCAT, PROV-O, SKOS, Schema.org, OpenLineage, ODCS**.

Why this matters, concretely, and not as buzzwords: RDF + OWL gives you
**inference**. If `dim_customers.email` is classified PII, and `fct_orders`
derives from it via a lineage edge, a reasoner can infer that `fct_orders` may
carry PII — nobody had to tag it. And SPARQL lets one query answer "every
dashboard that transitively depends on any column tagged PII.Sensitive and whose
owning team is X" — a graph traversal that would be a nightmare in REST calls
and impossible to hardcode as an agent tool.

The general lesson, worth more than the specific product: **JSON Schema gives
you structure; an ontology gives you meaning that machines can reason over.**
This is the "neuro-symbolic" idea — the LLM handles ambiguity and language, the
symbolic graph handles precision and constraints. Each covers the other's
failure mode.

**5. MCP server.** Shipped in 1.12 alongside a Metadata AI SDK; improved through
1.13.x (registry publication, per-tool metrics, response-size caps to avoid
blowing up LLM context, proper HTTP error codes). It exposes search, lineage
inspection, and semantic (vector) search over metadata to any MCP client. Auth
via OAuth or Personal Access Token, and — importantly — **tokens inherit the
creator's RBAC**, so the agent is governed by the same policies as a human user.
That last property is the whole argument for going through the catalog instead
of handing the agent a database password.

Note the response-size cap detail: it's a real design lesson. Metadata search
can return megabytes; an MCP tool that doesn't bound its output destroys the
agent's context window. Bound your own tools the same way.

### Where it fits

OpenMetadata is the agent's **discovery and trust layer**; Cube is its
**computation layer**. Agent flow: search the catalog to find the right asset
and confirm it's fresh and non-sensitive → map to a Cube view → query. Two
tools, two questions, cleanly separated.

---

## 7. pi — the agent harness

### What pi is

An open-source, MIT-licensed, terminal-native coding agent and **agent harness**
by Mario Zechner (`badlogic/pi-mono`, published as `@mariozechner/pi-coding-agent`
/ `@earendil-works/pi-coding-agent`). Its thesis is radical minimalism: a tiny
core with ~7 built-in tools (`read`, `bash`, `edit`, `write`, `grep`, `find`,
`ls`) and everything else pushed into extensions. No SaaS backend; 15+ model
providers with mid-session switching.

### Why it's the right harness for this project

Because it's small enough to read. You're not learning "how to use a product,"
you're learning **how agent harnesses work** — tool dispatch, context assembly,
the streaming event loop, permission gating. Pi makes all of that a TypeScript
API you can hold in your head.

Its four run modes map neatly onto what you need:
- **interactive TUI** — daily driving and debugging
- **print/JSON** — scripted evals (`pi -p "question" --json`)
- **RPC** — driving pi from a non-Node process
- **SDK** — embedding an agent in your own app

### The building blocks

**Extensions** — a TypeScript module exporting a factory that receives
`ExtensionAPI`. Auto-discovered from `~/.pi/agent/extensions/` (global) or
`.pi/extensions/` (project-local), hot-reloadable with `/reload`, testable with
`pi -e ./my-extension.ts`:

```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "cube_query",
    label: "Cube Query",
    description:
      "Run a query against the Cube semantic layer. Call describe_semantics " +
      "first to learn valid measure and dimension names.",
    parameters: Type.Object({
      measures: Type.Array(Type.String()),
      dimensions: Type.Optional(Type.Array(Type.String())),
    }),
    async execute(_id, params) {
      const rows = await queryCube(params);          // your HTTP call
      return { content: [{ type: "text", text: toMarkdownTable(rows) }],
               details: { rowCount: rows.length } };
    },
  });

  // governance gate — the agent must not read PII
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "cube_query" && touchesPII(event.input)) {
      return { block: true, reason: "Blocked: query touches PII.Sensitive members." };
    }
  });

  // inject fresh platform state into the system prompt each run
  pi.on("before_agent_start", async (event) => ({
    systemPrompt: event.systemPrompt + "\n\n" + await renderAssetFreshness(),
  }));
}
```

Those three hooks are the whole project in miniature: **a tool**, **a policy
gate**, and **context injection**.

**Skills** — capability packages (instructions + tools) loaded *on demand*. This
is the answer to context bloat: you don't want 40 tool schemas and 5000 words of
Cube documentation in every conversation. A `cube-modeling` skill loads only
when the user is actually editing cubes.

**Prompt templates** — Markdown files exposed as `/name` commands. Good for
`/daily-quality-report`.

**Packages** — bundle extensions + skills + prompts + themes and share via npm
or git (`pi install npm:@you/pi-data-platform`), declared under a `pi` key in
`package.json`. Your finished agent should be one of these.

**SDK** — for the headless/eval path:

```typescript
const modelRuntime = await ModelRuntime.create();
const { session } = await createAgentSession({
  customTools: [cubeQuery, catalogSearch],
  tools: ["read", "bash", "cube_query", "catalog_search"],
  modelRuntime,
  sessionManager: SessionManager.inMemory(),
});
await session.prompt("Which categories missed the delivery SLA last quarter?");
```

### Custom tools vs MCP — how to decide

Both OpenMetadata and (via your own server, per `docs/mcp-cube-guide.md`) Cube
speak MCP. Pi can also register native tools. The rule:

- **MCP** when the server is external, reusable across hosts, or someone else
  maintains it → OpenMetadata's MCP server, your Cube MCP server.
- **Native pi extension tools** when the logic is orchestration glue specific to
  this agent → the "check freshness then decide whether to trigger Dagster"
  composite tool, policy gates, context injection.

The interesting design work is in that composite layer. A tool named
`answer_business_question` that internally does catalog-search → semantics-lookup
→ query → provenance is a *worse* agent (opaque, unrecoverable). Small,
composable, well-described tools with excellent error messages is the pattern
that works — as `docs/mcp-cube-guide.md` already argues: **tool descriptions are
prompt, and errors are prompt.**

---

## 8. Why each tool, and what the alternatives teach

| Job | Chosen | Alternatives | Why this one here |
|---|---|---|---|
| Ingestion | Airbyte | Fivetran, Meltano, dlt, custom | Open source, huge catalog, real protocol to learn, OSS-deployable. `dlt` is a great lighter alternative if you want Python-native |
| Transform | dbt | SQLMesh, plain SQL | Ubiquitous; every other tool in the stack integrates via its manifest |
| Orchestrate | Dagster | Airflow, Prefect, Kestra | Asset-centric model matches "is this data fresh?" — the question agents ask |
| Semantics | Cube | dbt Semantic Layer, LookML, MetricFlow | Mature API, pre-aggregations, easy self-host, clean JSON meta for tools |
| Catalog | OpenMetadata | DataHub, Amundsen, Unity Catalog | Ontology/RDF + first-party MCP server; the most agent-ready of the OSS catalogs |
| Agent | pi | Claude Code, LangGraph, custom | Small, readable, extensible; teaches harness internals rather than hiding them |

The point of naming alternatives is that after this project you should be able to
argue for or against each choice, not just operate the one you learned.

---

## 9. The learning + implementation plan

Sequenced so you always have something working end-to-end, and each phase adds
one concept. Estimates assume evenings/weekends.

### Phase 0 — Finish Cube (you're here) · ~3–5 days

You already have cubes and a view over the seeded Olist Postgres. Complete it:

- Add delivery-time and review measures; write real `description:` prose.
- Add a second view for a different persona.
- Add one pre-aggregation; verify routing with Cube's query plan / dev playground.
- Build the Cube MCP server from `docs/mcp-cube-guide.md` and drive it from a
  host.

**Checkpoint:** an LLM answers a metric question through the semantic layer and
recovers from a bad member name on its own.

**Read:** Cube docs — Data modeling, Joins & cardinality, Views, Pre-aggregations.

---

### Phase 1 — Ingestion with Airbyte · ~1 week

- Split your Postgres into `source` (an "operational DB") and `warehouse`.
- Get the CSVs into the source DB; make Airbyte responsible for `source → raw`.
- Start with **PyAirbyte in a script**; get an incremental sync working with a
  cursor; deliberately break it (change a column type) and observe schema drift.
- Then install the full platform (`abctl local install`), rebuild the same
  connection in the UI, and inspect the STATE blobs.
- Add `source-faker` as a second source producing `web_events`.

**Checkpoint:** `raw` is populated entirely by Airbyte; re-running syncs is
incremental; you can explain STATE, catalog, and each sync mode.

**Read:** Airbyte Protocol spec (~30 min, high value), Sync modes, Incremental
append + dedup.

---

### Phase 2 — dbt over the raw layer · ~4–6 days

- `staging → intermediate → marts` over `raw`, with the grain problems called
  out in §3.
- Tests on every mart key; `schema.yml` descriptions written for a machine
  reader.
- Repoint Cube at `marts` instead of the seeded tables.

**Checkpoint:** `dbt build` is green; Cube queries return identical numbers to
before, now sourced from modeled marts.

---

### Phase 3 — Dagster unifies the graph · ~1 week

**Largely done — see `docs/orchestration.md`.** It landed as components rather
than Python: two `defs.yaml` files (`dagster_airbyte.AirbyteWorkspaceComponent`,
`dagster_dbt.DbtProjectComponent`) plus a four-line `definitions.py`, giving 21
Airbyte assets + 34 dbt assets + 108 tests as asset checks in one graph. The
`@dbt_assets`/manifest wiring below is what `DbtProjectComponent` does
internally, so it is no longer worth hand-rolling.

Still open:

- A daily partition on the facts, and freshness checks.
- A downstream asset that refreshes Cube pre-aggregations — the last hop that
  would make the graph reach all the way to the semantic layer.

Already in place: Airbyte assets upstream of dbt (joined by asset key, see the
"asset key contract" section of the orchestration doc), `on_cron` on ingestion
and `AutomationCondition.eager()` on every dbt model.

**Checkpoint:** one `dagster dev` UI shows source → raw → staging → marts →
Cube as a single lineage graph, and changing a source triggers exactly the
right subset.

**Read:** Dagster — Software-defined assets, Declarative automation, dbt
integration.

---

### Phase 4 — OpenMetadata · ~1.5 weeks (the deepest phase)

1. Deploy via Docker Compose. Get the UI up, create a Team, add yourself.
2. Run the **Postgres** ingestion workflow (metadata + profiler + sample data).
   Browse what lands.
3. Run **dbt ingestion** against `manifest.json` / `run_results.json`. Confirm
   descriptions, tests, and model lineage appear.
4. Run **Airbyte** and **Dagster** connectors. You should now have end-to-end
   lineage from source system to mart.
5. Build a **Glossary**: *Net Revenue*, *Delivery SLA*, *Active Seller*. Link
   terms to columns. Add a `PII` classification and tag customer columns.
6. Explore the **Knowledge Graph** UI, then the **RDF/SPARQL** side: export
   metadata as JSON-LD, load into a triple store (or use the endpoint), and
   write two SPARQL queries — one traversal ("everything downstream of column
   X"), one inference-flavored ("assets that may carry PII transitively").
7. Turn on the **MCP server**, create a PAT, connect an MCP client, and ask it
   catalog questions.
8. Make OpenMetadata ingestion a **Dagster asset** downstream of dbt.

**Checkpoint:** you can trace one column from CSV to Cube measure in the
lineage UI, and an MCP client can answer "who owns this and is it fresh?"

**Read:** OpenMetadata — Metadata Standard / core schema; MCP docs;
`openmetadatastandards.org/rdf/overview`.

#### What Phases 5 and 6 specifically need out of this phase

The list above is the full OpenMetadata tour. These four items are the ones that
*block* the two agent phases, in priority order — everything else in Phase 4 can
slip:

1. **dbt ingestion (step 3).** Highest priority and currently missing.
   `orchestration/defs/openmetadata/definitions.py` ingests the Postgres schema
   only, so OpenMetadata knows `silver_marts.fct_subscriptions` exists as a
   table but not that a dbt model produces it, what its columns mean, or which
   tests guard it. Phase 5's agent has nothing meaningful to attach terms to
   until dbt descriptions, tests and model lineage land as entities.
2. **A bot account with write scope, and its RBAC boundary decided.** Phase 5's
   agent writes to the catalog. OpenMetadata tokens inherit the creator's RBAC,
   which is the whole argument for going through the catalog — so give the
   curation agent its own bot, not the ingestion bot's token, and scope it to
   the domains it is allowed to touch.
3. **Olist through Airbyte (Phase 1's `source-postgres` path).** Olist is
   currently loaded by `db/seed.sql` straight into the warehouse, so it has no
   `raw` layer. Phase 6's agent is supposed to build `raw → staging →
   intermediate → marts`; without a real raw schema its staging models are
   modeling a seed script, and the medallion story is a fiction. This is the one
   Phase 1 item that is genuinely load-bearing for the demo.
4. **Airbyte + Dagster connectors (step 4).** Needed for the end-to-end lineage
   claim in Phase 6's acceptance criteria, not for the agent to function.

Steps 5–7 (hand-building a glossary, SPARQL, the MCP server) are still worth
doing — but note that **step 5 is the task Phase 5 automates.** Build the Stripe
glossary by hand anyway: it is the reference implementation the agent's Olist
glossary gets scored against, and writing it by hand is how you learn which API
calls the agent's tools need to wrap.

---

### Phase 5 — The curation agent (replaces the Data Steward) · ~1.5 weeks

**Goal:** `pi --agent data-steward` reads a Markdown domain brief plus the
technical metadata already in OpenMetadata, and produces the domain, glossary,
terms, classifications and asset links — reviewed by a human as a diff, not
typed by one.

#### The input contract: `domains/<domain>.md`

This file is the crux of the whole phase, and the temptation is to over-specify
it. **Resist making it machine-readable.** If the brief is structured enough to
be compiled, the agent is a YAML transpiler and the demo proves nothing. The
point is that a domain expert writes *prose* about their business and the agent
does the modeling work.

So: prescribed sections, free prose inside them.

```markdown
---
domain: Marketplace Orders
owner: marketplace-analytics
source_service: warehouse-postgres
---

## What this domain is for
Two-sided marketplace: customers place orders, sellers fulfil them, couriers
deliver them. The questions we need to answer are about delivery reliability and
which sellers and categories drive it.

## Tables
`olist_orders_dataset` — one row per order. Five timestamp columns; the one that
means "when the customer bought" is `order_purchase_timestamp`, the rest are
fulfilment milestones. `order_estimated_delivery_date` is the promise made at
checkout, not a prediction.

`olist_order_items_dataset` — one row per *item*, not per order. An order with
three items is three rows. Revenue lives here.
...

## Business vocabulary
**Delivery SLA** — an order meets its SLA when it reaches the customer on or
before `order_estimated_delivery_date`. Measured at order grain, never item
grain.

**Active Seller** — a seller with at least one order in the trailing 90 days.
...

## Sensitivity
Customer zip prefixes and city are personal data under our policy. Seller
identifiers are not.
```

Two things make this format work rather than being decoration:

- **Grain statements live in the vocabulary section.** "Measured at order grain,
  never item grain" is the single most valuable sentence in the file, because it
  becomes a GlossaryTerm description, which Phase 6 then reads back when
  choosing a mart's grain, which becomes a dbt uniqueness test. Trace that
  chain — it is how a prose sentence turns into an executable assertion. The
  hand-written Stripe cubes already do this (see the `GRAIN WARNING` block in
  `cube_semantics/model/views/revenue_overview.yml`); the brief is where that
  knowledge enters the system instead of being retrofitted at the end.
- **The brief never names an OpenMetadata entity type.** No "create a
  GlossaryTerm called X". The mapping from business prose to catalog entities is
  the agent's job, and it is the part being demonstrated.

#### What the agent writes

| OpenMetadata entity | Sourced from |
|---|---|
| `Domain` | frontmatter |
| `Glossary` + `GlossaryTerm` (with `synonyms`, hierarchy via `parent`) | the vocabulary section |
| Term → column links | the agent matching term definitions against ingested columns |
| `Classification` tags (`PII.Sensitive`) on columns | the sensitivity section |
| Table and column `description` patches | the tables section + inference from names/types |
| `DataProduct` (optional) | the use-cases section |

#### Tools

OpenMetadata's MCP server is search/lineage-shaped — it is a read surface. Writes
go through the REST API, so this phase is a **native pi extension**, not MCP.
Keep the tools small and boring:

```
om_search_assets(query, limit)          om_create_glossary(name, description)
om_get_table(fqn)                       om_create_term(glossary, name, description,
om_patch_description(type, fqn, text)                   synonyms, parent)
om_apply_tag(fqn, column, tag_fqn)      om_link_term(term_fqn, asset_fqn, column?)
om_create_domain(name, description)     om_assign_domain(fqn, domain)
```

Four rules, each of which is the difference between a demo and a liability:

1. **Idempotent by FQN.** Every write is create-or-update keyed on the fully
   qualified name — `PUT`, never blind `POST`. Re-running the agent against an
   unchanged brief must produce zero writes. This is also the most convincing
   thing you can show a governance audience.
2. **Bounded output.** `om_search_assets` over a real catalog returns megabytes.
   Cap it — the same lesson OpenMetadata learned capping their own
   `search_metadata` (§6.5).
3. **Errors are prompt.** OpenMetadata validates writes against JSON Schema and
   SHACL shapes and rejects bad metadata with a specific message. Surface that
   message verbatim in the tool result and the agent self-corrects in one turn.
   Do not swallow it into "write failed".
4. **Dry-run is the default.** `--plan` renders the intended writes as a Markdown
   diff and exits; `--apply` executes. The steward role is not deleted, it is
   inverted: the human stops typing and starts reviewing.

#### Acceptance criteria

- Every term in the brief's vocabulary section exists as a `GlossaryTerm` and is
  linked to at least one column. **No orphan terms.**
- Every column the brief discusses carries a description; every column flagged
  sensitive carries the classification.
- **Idempotency:** second run on an unchanged brief → zero writes.
- **Convergence:** edit one definition in the brief, re-run → exactly one term
  updated, nothing else touched.
- A reviewer shown the agent's Olist glossary and the hand-written Stripe
  glossary side by side cannot reliably say which is which.

#### Eval

Fifteen to twenty assertions run headless (`pi -p --json`) against a freshly
reset OpenMetadata: term exists, term linked to the *right* column, PII applied
to exactly the right set, no orphans, idempotent re-run. Structural assertions
first — they are cheap, deterministic, and catch most regressions.

For description *quality*, use an LLM judge in a separate session, given the
hand-written Stripe glossary as the reference standard and a rubric (does it
state grain? does it warn about the obvious wrong join? is it written for a
machine reader?). Never let the authoring session grade its own output.

---

### Phase 6 — The generation agent (replaces the Data Engineer) · ~2 weeks

**Goal:** `pi --agent data-engineer` takes the governed metadata from Phase 5
plus one sentence of business intent, and produces a working medallion pipeline.

> *"I need to see which sellers are missing the delivery SLA, broken down by
> state and product category, month over month."*

#### Why this is a loop, not a code generator

A one-shot template that emits dbt models from a schema is a solved, boring
problem and it produces plausible-looking wrong SQL. What makes this an agent is
that **every stage produces a machine-checkable signal the agent must react to**:

```
  1 PLAN        read OM: tables, grains, glossary terms behind "Delivery SLA"
                → emit target marts + declared grain + measures   ← human approves, once
  2 SCAFFOLD    write stg_* / int_* / dim_*+fct_* / schema.yml
  3 BUILD       dbt build            → compile + test failures are the signal
  4 SEMANTICS   write cubes + a view, joins with declared cardinality
  5 VERIFY      cube run_query vs an independently-written SQL query
  6 REGISTER    re-run OM ingestion; link new mart columns back to the terms used
```

Step 6 is what closes the circle and is worth stating plainly: **Phase 5's
output is Phase 6's input, and Phase 6's output flows back into Phase 5's
catalog.** The semantic layer is not a static document the agents consult — it
is a shared artifact they both maintain.

#### Grain is the whole difficulty

Everything else here is mechanical. Grain is where LLMs writing warehouse SQL
actually fail — `fct_order_items` at item grain versus `fct_orders` at order
grain, and revenue silently double-counted across the join. Three defences,
stacked:

1. **The glossary carries grain in prose.** "Measured at order grain, never item
   grain" came from the brief in Phase 5 and the agent reads it in step 1.
2. **The plan declares grain explicitly.** Step 1's output must name each mart's
   grain key. This is the thing the human approves.
3. **The declared grain becomes a test.** Every mart gets a `unique` test on its
   declared grain key, generated in step 2 and executed in step 3. A grain
   mistake is now a red `dbt build`, not a wrong number nobody notices.

That is the entire architectural argument of this project compressed into one
mechanism: prose → governed metadata → generated code → executable assertion.

#### Tools

pi already ships `read`/`write`/`edit`/`bash`/`grep`/`find`, which is all the
*authoring* capability needed. **Do not build a `generate_dbt_model` tool** — a
tool that writes the model for the agent makes the agent worse, not better
(§7, "custom tools vs MCP"). The new tools are all *feedback*:

| Tool | Returns |
|---|---|
| `dbt_build(select)` / `dbt_test(select)` | structured failures, bounded — not 4000 lines of log |
| `cube_validate()` | Cube schema compile errors |
| `describe_semantics` / `run_query` / `explain_query` | existing MCP server, unchanged |
| `dagster_materialize(assets)` / `check_asset_freshness(asset)` | Dagster GraphQL |
| the Phase 5 OpenMetadata read tools | glossary terms, table schemas, lineage |

Dagster needs almost no new work: `DbtProjectComponent` builds assets from
`manifest.json`, so new dbt models become Dagster assets automatically the moment
they compile. The only genuinely new Dagster asset is the Cube pre-aggregation
refresh that Phase 3 left open — and generating pre-aggregations is out of scope
for v1. Say so rather than discovering it mid-demo.

#### "Minimal user interaction" needs a number

Otherwise it is unfalsifiable. Define the interaction budget and log every human
turn:

- **1** goal statement
- **1** approval of the step-1 plan
- **0** corrections

Three human turns total, ≤ 2 of them substantive. That number is the demo metric;
publish it in the eval output.

#### Acceptance criteria

- `dbt build` green, including the grain uniqueness test on every declared mart.
- A Cube query against the generated view answers the original goal, and the
  number matches an independently hand-written SQL query.
- Dagster shows raw → staging → intermediate → marts as one graph with correct
  upstream edges, and no phantom dependencies.
- OpenMetadata shows column-level lineage from the raw Olist tables to the new
  marts, and the new mart columns carry the glossary terms the agent used.
- Human turns ≤ 3.
- **The comparison:** the same reviewer scores the agent's Olist marts and cubes
  and the hand-written Stripe ones against one rubric. Parity is the claim.

#### Where it will fail — plan for these

- **Grain**, as above. Mitigated, not eliminated.
- **Olist has no incremental cursor.** It is a static CSV load, so schema drift
  and STATE — the interesting halves of the ingestion story — do not exercise.
  Phase 4 prerequisite #3 fixes the raw layer, not this.
- **Cube pre-aggregations and join-path tuning** are performance work with weak
  feedback signals. Out of scope for the agent; keep them hand-written.
- **Context bloat.** An unbounded `om_search_assets` or a raw `dbt build` log
  will eat the window mid-run. This is why every tool above is described as
  bounded.

#### Model and harness notes

pi speaks 15+ providers with mid-session switching, so the model is a config
choice — pin it in the package and record it in every eval result, because model
version is an experimental variable.

Default to **Claude Opus 5** (`claude-opus-5`) for both agents; the Phase 6
build-verify loop is exactly the long-horizon agentic work it is strongest at.
Run the generation agent at `effort: xhigh` and the curation agent at `high`.
Three prompting notes that matter specifically here:

- **Give the complete task spec in the first turn.** Long-horizon performance is
  best with one well-specified opening turn rather than intent dribbled across
  several — which happens to be the same thing as the minimal-interaction goal.
  The interaction budget and the quality ceiling point the same direction.
- **Do not write "double-check your work" into the prompt.** Recent models
  verify unprompted and the instruction causes over-verification. Keep the
  *executable* verification (dbt tests, the Cube-versus-SQL comparison); drop the
  prose kind.
- **Cap subagent delegation explicitly.** Left alone the agent will spawn
  subagents for work it could do in three tool calls, multiplying cost and
  latency for no gain.

#### Eval

The Phase 5 eval checks structure. This one checks *behaviour*, so it has to
actually run the pipeline: reset the warehouse, hand the agent a goal, let it
build, then assert on the artifacts and the numbers. Run three or four distinct
goals against the same Olist domain — an SLA question, a revenue-by-category
question, a repeat-customer question — because a single golden path proves
nothing about generalisation. Score: build green, numbers match, human turns
used, and a judge's rubric score on the generated `schema.yml` descriptions and
Cube `description:` prose.

---

### Phase 7 — The analyst agent (the read path) · ~1.5 weeks

**Downstream of Phases 5 and 6, and the acceptance test for both.** Everything
this agent reads — glossary terms, classifications, marts, cubes — was produced
by the two write agents. Point it at the Olist domain specifically: if it can
answer a business question over metadata and models that no human authored, the
two roles were automated for real.

Build `pi-data-platform` as a proper pi package.

- **Tools** (small, composable, great errors):
  - `catalog_search`, `get_lineage`, `get_glossary_term` — via OpenMetadata MCP
  - `describe_semantics`, `run_query` — via your Cube MCP server
  - `check_asset_freshness`, `materialize_assets` — native extension tools over
    Dagster's GraphQL API
- **Policy gate** on `tool_call`: block queries touching members whose
  underlying columns are classified `PII.Sensitive` (look the classification up
  in OpenMetadata — this is where catalog and semantics genuinely compose).
- **Context injection** on `before_agent_start`: current asset freshness summary
  and the list of available Cube views.
- **A skill** `semantic-modeling` that loads Cube modeling guidance only when the
  user is authoring cubes.
- **A prompt template** `/data-health` producing a freshness + test-failure
  report.
- **An eval harness**: 15–20 questions with known answers, run headless via
  `pi -p --json` or the SDK, scored. This is the part most people skip and it's
  the part that tells you whether any of it works.

**Checkpoint:** the §0 scenario runs end-to-end, including the stale-data
detour where the agent triggers Dagster and re-answers.

---

### Phase 8 — Polish · ~1 week

- One `docker-compose.yml` (or Makefile targets) that stands the whole platform
  up from cold.
- A short write-up per tool: what it does, what broke, what you'd choose next
  time. Extend this doc's §8 table with your real opinions.
- Stretch goals, pick one: a custom Airbyte connector with the low-code CDK;
  SPARQL-driven impact analysis as an agent tool; Cube pre-aggregation
  auto-tuning driven by the agent's own query log.

---

## 10. Practical warnings

- **RAM.** Airbyte (kind cluster) + OpenMetadata (server + Elasticsearch + MySQL/
  Postgres) + Dagster + Cube + Postgres is heavy. 32 GB is comfortable, 16 GB
  means running phases in isolation. Prefer PyAirbyte if constrained.
- **Don't build all six before testing any.** After each phase the agent should
  be able to do something new. If phase 4 takes three weeks and the agent still
  can't do anything it couldn't do in phase 0, you've lost the plot.
- **Version pinning.** OpenMetadata connector configs and Dagster's dbt
  integration both change across minor versions. Pin everything in
  `pyproject.toml` and note the versions here.
- **Bound your tool outputs.** Every tool the agent calls must cap its response
  size — the exact lesson OpenMetadata learned when they capped
  `search_metadata`. An unbounded catalog search will eat the context window.
- **Write descriptions as you go.** dbt `schema.yml`, Cube `description:`,
  OpenMetadata glossary. Retrofitting documentation for 40 models is the task
  that kills the project in week six. Every description is agent capability —
  and for Stripe specifically, it is the reference standard Phase 5's agent
  gets graded against, so hand-writing it is not wasted work.
- **An agent with write access to the catalog is a different risk class.**
  Phases 5 and 6 hand an agent credentials that mutate governance metadata and
  the transformation repo. Three non-negotiables: every catalog write is
  idempotent and keyed by FQN (a non-idempotent retry duplicates your glossary),
  dry-run-then-apply is the default rather than an option, and the agent gets
  its own bot with its own RBAC scope instead of borrowing the ingestion bot's
  token. Demo the second run producing zero writes — that is the thing a
  governance audience actually wants to see.
- **Keep the golden domain hand-built.** The moment you let an agent "improve"
  the Stripe models, you have lost the control group and every comparison in
  Phases 5–7 becomes unfalsifiable. Stripe is written by a human, Olist by the
  agent, and that boundary does not move.

---

## Sources

- [pi.dev](https://pi.dev/) · [badlogic/pi-mono — SDK docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/sdk.md) · [extensions docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) · [packages docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md)
- [OpenMetadata](https://github.com/open-metadata/OpenMetadata) · [MCP docs](https://docs.open-metadata.org/v1.12.x/how-to-guides/mcp) · [Introducing MCP in OpenMetadata](https://blog.open-metadata.org/introducing-the-model-context-protocol-mcp-in-openmetadata-e757385f4fb2) · [Announcing 1.13](https://blog.open-metadata.org/announcing-openmetadata-1-13-123d66609468) · [RDF & Ontologies overview](https://openmetadatastandards.org/rdf/overview/) · [OpenMetadataStandards repo](https://github.com/open-metadata/OpenMetadataStandards)
- [Airbyte](https://github.com/airbytehq/airbyte) · [Cube](https://github.com/cube-js/cube)
