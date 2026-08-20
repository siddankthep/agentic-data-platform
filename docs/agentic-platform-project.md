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

A local, reproducible **scaffold** that lets a terminal agent stand up a complete
data platform on *any* source a person already has: it profiles and documents the
source, ingests it into a warehouse the person chooses, and builds the
transformation, semantic and orchestration layers for a use case stated in one
sentence — so the agent always works from governed metadata and a semantic layer,
never raw SQL against tables it half-understands.

### The workflow, from the user's side

Three steps, each handing context to the next:

1. **Connect your source.** Point OpenMetadata at whatever you already have —
   Postgres, Snowflake, anything with a connector. It profiles the source, and the
   agent reads that technical metadata to produce the *governed context*: a
   glossary, tags and classifications, semantic hints, and a Markdown brief that
   documents every table, column and use case. Everything needed to understand the
   source before a byte is moved.
2. **Choose a destination.** Pick the warehouse that will hold the transformed
   data. Airbyte — declared in Terraform, not clicked together in a UI — ingests
   the source into it as a `raw` layer.
3. **State a use case.** Hand the agent one sentence of business intent. It writes
   the dbt models that transform `raw` bronze into gold marts, the Cube cubes and
   views that serve the use case's semantics, and the Dagster wiring that
   orchestrates the whole graph.

The end product is a fully-functioning data platform the agent spun up, carrying
the metadata that gives the agent correct context about its own inputs and
outputs — and it is plug-and-play: anyone can clone the scaffold, point it at
their own source, and get the same result.

### The architecture

```
                          ┌───────────────────────────────────────┐
                          │        pi agent  (the scaffold)        │
                          │   curation · generation · analyst      │
                          └───┬──────────┬───────────┬─────────────┘
                   MCP/REST   │          │ MCP       │ GraphQL
              ┌───────────────┘          │           └──────────────┐
              ▼                          ▼                          ▼
      ┌───────────────┐          ┌──────────────┐          ┌────────────────┐
      │ OpenMetadata  │          │     Cube     │          │    Dagster     │
      │ understand +  │          │ semantic     │          │ orchestration  │
      │ glossary +    │          │ layer        │          │ + asset graph  │
      │ tags/lineage  │          │ (agent-built)│          │ (agent-wired)  │
      └──┬─────────▲──┘          └──────▲───────┘          └────┬───────────┘
   ① profile      │ ③ catalog          │ SQL                   │ triggers
     source       │   warehouse        │                       │ syncs/builds
         │        │            ┌───────┴───────────────────────▼──┐
         │        └───────────►│       Destination warehouse       │
         │                     │  raw.*  (Airbyte)  →  marts.*     │
         │                     │                    (dbt, agent)   │
         │                     └───────────────────▲──────────────┘
         ▼                                          │ ② ingest
   ┌───────────┐                          ┌─────────┴──────────┐
   │  YOUR     │─────────────────────────►│      Airbyte       │
   │  source   │      EL: source → raw    │  (declared in      │
   │ postgres/ │                          │   Terraform)       │
   │ snowflake │                          └────────────────────┘
   │   / …     │
   └───────────┘
```

The circled numbers are the three steps: ① the agent profiles and documents the
source through OpenMetadata *before* any load; ② Airbyte ingests the source into
the chosen warehouse as `raw`; ③ the agent builds the marts, cubes and
orchestration, and OpenMetadata catalogs the warehouse so lineage reaches from
the source all the way to the served view.

### The end product — be concrete

When you're done — on *your own* source, whatever it is — you should be able to
run:

```bash
pi --agent data-platform
> <a business question about the use case you asked the agent to build for>
```

and watch the agent do roughly this:

1. `search_catalog("<subject>")` → OpenMetadata returns the matching mart, its
   owner, description, freshness, and the relevant glossary term.
2. `describe_semantics()` → Cube returns the cube and its measures, with the
   joins it needs already declared.
3. `run_query({measures, dimensions, filters})` → Cube compiles to SQL, hits the
   warehouse, returns rows. No hallucinated join keys, because joins are declared
   in the semantic layer, not invented by the model.
4. `get_lineage("<fqn>")` → the agent can say where a column came from: which raw
   table, synced by which Airbyte connection, transformed by which dbt model.
5. `check_freshness()` / `trigger_pipeline()` → if the data is stale, the agent
   asks Dagster to materialize the affected assets, then re-answers.

That loop — **discover → understand semantics → query safely → explain
provenance → repair staleness** — is the *read* path. It is the easiest of the
three roles and the last to be built, because everything it reads was produced by
the other two.

### The three agent roles

The scaffold is driven by one pi agent playing three roles, matching the three
steps of the workflow:

**1. The curation agent — understand the source.** Given a source connected to
OpenMetadata, it reads the ingested technical metadata and produces the governed
context: a Markdown brief per table / column / use-case, a glossary with terms
and synonyms, tags and PII classifications, and the semantic hints (grain, join
keys, metric definitions) the next role needs. The catalog stops being
documentation a human maintains and becomes an artifact the agent curates.
→ **Phase 2**

**2. The generation agent — build the pipeline.** Given that governed context
plus a one-sentence use case, it generates the medallion pipeline that answers
it: dbt staging → intermediate → marts, Cube cubes and a consumer-facing view,
and the Dagster wiring — with minimal human interaction and a build-verify loop
that proves the output correct rather than merely plausible. → **Phase 4**

**3. The analyst agent — prove it works.** The read path above. It is also the
**acceptance test** for the other two: if an agent can answer a business question
through metadata and marts that no human wrote, the platform was genuinely built.
→ **Phase 5**

The pipelines underneath are the substrate that makes all three possible.

### The shipped example, and why it's removable

This repo currently contains a complete, hand-built **Stripe** pipeline: 21 dbt
staging models, 11 marts, 11 Cube cubes, 2 views, an Airbyte Stripe→Postgres
connection, and the Dagster graph over all of it. Treat it as a **worked
example**, not the product. It shows what "done" looks like end-to-end, and while
the agent roles are still being built it is the reference their output is read
against. **Phase 0** extracts it into a removable `examples/stripe/` demo so the
scaffold underneath is source-agnostic — clone, delete the example, point at your
own source, and the three roles fill the empty template directories back in.

### Why this is a good scaffold

Every layer carries a distinct concept that generalizes across any source:

| Layer | Concept it embodies |
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

An LLM pointed at a raw warehouse fails in a predictable way. Given a raw
`orders` table with a handful of timestamp columns, it will:

- guess which timestamp is "the" order date when several exist and the right one
  depends on the question,
- invent a join to an `order_items` table and then double-count revenue because
  the grain changed,
- compute a metric like "delivery time" three different ways across three
  conversations,
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

In the scaffold, Airbyte owns exactly one job: move the user's chosen **source**
into the chosen **destination warehouse** as a `raw` layer, declared in Terraform
(§Phase 3). Nothing downstream ever reads a source directly — dbt models `raw.*`,
and `raw.*` only exists because Airbyte put it there.

- The **Stripe example** is the reference connection: `source-stripe` →
  `destination-postgres` into `raw`, all in `ingestion/terraform/`. It shows the
  shape a new source/destination pair has to match.
- The parameterization work is making both ends a variable: a
  `source-postgres`/`source-snowflake` reading the user's operational system, and
  a destination the user selects. The connector protocol is identical whichever
  pair you pick — that is the whole point of Airbyte.
- Optional stretch: a **custom connector** with the low-code CDK for a source with
  no off-the-shelf connector. This is where you truly learn the protocol.

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

The interesting modeling problems the generation agent has to get right, whatever
the source, are the recurring ones:

- **Grain and fan-out** — a fact at item grain versus order grain, with revenue
  double-counted across a join. This is the classic bug, and exactly what Cube's
  `join` cardinality declarations protect against downstream (§Phase 4 stacks
  three defences on it).
- **Conformed dimensions** — a dimension that needs a lookup or translation table
  joined in before it is usable.
- **A metric defined once** — a derived measure (a duration, a ratio, a
  net-of-something) computed in exactly one mart and exposed by Cube, rather than
  reinvented per query. This is the concrete instance of "one metric definition."

The Stripe example demonstrates each of these; the agent reproduces them for a new
source.

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
don't take that dependency in a scaffold whose whole value is the ecosystem
integrations.

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
raw/<stream_a>  ────────► stg_a ──► int_… ──► fct_a ──────────► cube_preagg_refresh
raw/<stream_b>  ────────► stg_b ──┘                          └─► openmetadata_ingest
raw/<stream_c>  ────────► stg_c ──► fct_c ─────────────────────┘
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

The Stripe example in `cube_semantics/model/` already has 11 cubes and 2 views —
the reference for what the generation agent produces per source. This section
explains *why* that shape matters.

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
- **View** — a curated, consumer-facing bundle of members from several cubes. The
  example's `revenue_overview.yml` is one. **Views are what you expose to the
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

### What good looks like (the bar the agent has to clear)

The Stripe example sets the standard the generation agent's Cube output is scored
against:

- Descriptive measures with real `description:` prose — every metric the use case
  needs, defined once, with its grain stated.
- At least one pre-aggregation, so the query plan can route to a rollup (kept
  hand-written; auto-tuning pre-aggregations is out of scope for the agent, §Phase
  4).
- A consumer-facing **view** per persona, not just raw cubes — two views make the
  "curated surface" idea click.
- Every `title:` and `description:` field written as agent-quality prose, because
  `/v1/meta` turns them straight into the tool schema the analyst agent reads.

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

## 9. Where the scaffold stands, and the plan to finish it

### What already works (the Stripe example)

The substrate is built once, by hand, as the Stripe worked example — proof the
wiring is correct before any agent touches it:

| Layer | State | Where |
|---|---|---|
| Warehouse | Postgres in Docker Compose, `pg_stat_statements` on | `docker-compose.yml` |
| Ingestion | Airbyte via `abctl` + Terraform: Stripe source → `raw` | `ingestion/terraform/` |
| Transform | dbt: 21 staging + 2 intermediate + 11 marts, tested | `transformation/` |
| Semantics | Cube: 11 cubes + 2 views, hand-written descriptions | `cube_semantics/model/` |
| Orchestration | Dagster: Airbyte + dbt in one asset graph | `orchestration/defs/` |
| Catalog | OpenMetadata: base services in Compose, nothing ingested yet | `docker-compose.yml` |
| Agent surface | Cube MCP server | `cube_mcp_server/` |

Four of the six platform layers are already end-to-end for one source. So the
remaining work is **not "build the layers"** — it is to make them source-agnostic
and put the three agent roles on top, in the order the workflow runs. Each phase
below leaves the scaffold able to do something new on an *arbitrary* source, not
just on Stripe.

The concept sections above (§2–§7) still describe every layer in full; what
follows is only the build order.

---

### Phase 0 — Genericize the scaffold (extract the Stripe example) · ~1 week

Today every layer is Stripe-shaped. Turn the repo into a template a stranger can
point at their own source.

- Move the Stripe-specific artifacts into a removable `examples/stripe/`: the dbt
  models under `transformation/models/`, the cubes and views under
  `cube_semantics/model/`, and the Stripe source/connection Terraform.
- Leave the template directories empty but documented — each gets a short README
  stating the *contract* the agent fills: the `staging → intermediate → marts`
  boundaries for dbt, the cube-vs-view split for Cube, the source and destination
  stubs for Terraform.
- Parameterize configuration: `.env` selects the source and the destination
  warehouse; the Dagster `defs.yaml` translation key and the Terraform variables
  stop hard-coding `stripe`.
- Prove it by standing the scaffold up with the example deleted — every service
  comes up green over an empty pipeline, ready for a source.

**Checkpoint:** `make up` gives you every service with no Stripe assumptions
baked in; `examples/stripe/` can be copied back as a reference at any time.

---

### Phase 1 — OpenMetadata: understand any source · ~1.5 weeks

Step 1 of the workflow, and the substrate for the curation agent: the catalog
must connect to a source the user already has and expose its technical metadata
*before* any load.

1. Deploy is already in Compose — get the UI up, create a Team, add yourself.
2. Wire the **source connectors** the scaffold advertises: Postgres and Snowflake
   first (metadata + profiler + sample data), each declared as config, not
   clicked in the UI. Point one at a real source and browse what lands.
3. Run **dbt ingestion** against the example's `manifest.json` / `run_results.json`
   so descriptions, tests and model lineage appear — the same shape the generation
   agent's output must later produce.
4. Make metadata ingestion a **Dagster asset** so the catalog refreshes on the
   same graph as everything else. (`orchestration/defs/openmetadata/` does not
   exist yet — this is where it lands.)
5. Turn on the **MCP server**, and create a **bot with its own scoped RBAC** — not
   the ingestion bot's token — because the curation agent writes through it and
   OpenMetadata tokens inherit the creator's permissions.

**Checkpoint:** connect an unfamiliar Postgres/Snowflake source and, in the UI
and over MCP, see its tables, columns, profiles and sample data; an MCP client
answers "what exists here and who owns it?"

**Read:** OpenMetadata — Metadata Standard / core schema; connectors; MCP docs;
`openmetadatastandards.org/rdf/overview` for the ontology/SPARQL side (optional,
but it is what makes transitive PII inference in §6 real).

---

### Phase 2 — The curation agent: source → context · ~1.5 weeks

**Goal:** `pi --agent data-steward` reads the profiled technical metadata of a
source already connected to OpenMetadata (Phase 1) and produces the governed
context a data steward would otherwise hand-write: a Markdown source brief, a
glossary with terms and synonyms, PII classifications, and description patches —
all reviewed by a human as a diff, never typed by one.

This inverts the classic steward workflow. Instead of a human writing a brief and
the agent transcribing it into the catalog, **the agent drafts the brief from the
profiled source** — column names and types, sample data, row counts, null rates,
key candidates — and the human's job shrinks to confirming or correcting it. One
optional input keeps it grounded: a few sentences of domain context (what the
source is *for*), because sample data reveals structure but not intent.

#### The primary output: `docs/sources/<source>.md`

The brief is the agent's main deliverable and the human-review surface. It is
prose, not a config file — if it were structured enough to compile, the agent
would be a transpiler and would prove nothing. Prescribed sections, free prose
inside them:

```markdown
---
source: <source name>
service: <the OpenMetadata service it was ingested through>
generated_by: data-steward agent   ·   reviewed_by: <human>
---

## What this source is for
<the agent's summary of the domain, grounded in the optional human hint and in
what the tables and columns imply>

## Tables
`<table>` — one row per <grain the agent inferred from key candidates and row
counts>. <which columns matter, which timestamp means what, which column carries
the money, what looks like a foreign key>.
...

## Business vocabulary
**<Term>** — <definition the agent proposes from column semantics and sample
values>. Measured at <grain>, never <the wrong grain>.
...

## Sensitivity
<columns whose names, types or sample values look like personal data, flagged for
the human to confirm before the classification is applied>
```

Two things make this format load-bearing rather than decorative:

- **Grain statements carry through to executable assertions.** "Measured at order
  grain, never item grain" becomes a GlossaryTerm description, which Phase 4 reads
  back when choosing a mart's grain, which becomes a dbt uniqueness test. Trace
  that chain — it is how a prose sentence turns into a red build when violated.
  The hand-written Stripe cubes already show the target (the `GRAIN WARNING` block
  in the Stripe example's `revenue_overview.yml`); the brief is where that
  knowledge enters the system for a *new* source.
- **The brief never names an OpenMetadata entity type.** No "create a GlossaryTerm
  called X". The mapping from business prose to catalog entities is the agent's
  job, and it is the part being demonstrated.

#### What the agent writes to the catalog

| OpenMetadata entity | Inferred from |
|---|---|
| `Domain` | the source + the human's domain hint |
| `Glossary` + `GlossaryTerm` (with `synonyms`, hierarchy via `parent`) | column semantics, sample values, the vocabulary the agent drafts and the human confirms |
| Term → column links | the agent matching each term to the profiled columns that implement it |
| `Classification` tags (`PII.Sensitive`) on columns | column names/types + sample-data inspection, human-confirmed |
| Table and column `description` patches | inference from names, types and sample data |
| `DataProduct` (optional) | the use-cases the agent identified |

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
- A reviewer shown the agent's generated brief and glossary for a fresh source,
  next to the hand-written Stripe example, cannot reliably say which one a human
  authored.

#### Eval

Fifteen to twenty assertions run headless (`pi -p --json`) against a freshly
reset OpenMetadata: term exists, term linked to the *right* column, PII applied
to exactly the right set, no orphans, idempotent re-run. Structural assertions
first — they are cheap, deterministic, and catch most regressions.

For description *quality*, use an LLM judge in a separate session, given the
Stripe example's glossary as the reference standard and a rubric (does it state
grain? does it warn about the obvious wrong join? is it written for a machine
reader?). Never let the authoring session grade its own output.

---

### Phase 3 — Ingestion: source → the chosen warehouse · ~1 week

Step 2 of the workflow. The Stripe example already proves the
Airbyte-via-Terraform path (Stripe → Postgres `raw`); this phase makes both
*source* and *destination* a user choice rather than a hard-coded pair.

- Parameterize the Terraform in `ingestion/terraform/`: the source is whatever
  the user connected to the catalog in Phase 1; the destination is the warehouse
  they pick. Start with Postgres, but shape the variables so Snowflake/BigQuery
  slot in as destinations without rewriting the module.
- `make sync` lands the source into `raw` in that warehouse, with the STATE and
  sync-mode behaviour described in §2.
- Re-run OpenMetadata ingestion against the warehouse, plus the Airbyte connector,
  so lineage now spans **source → `raw`** and the connection is recorded.

**Checkpoint:** point the scaffold at a source and a fresh destination, run one
command, and `raw.*` fills with the source's tables; lineage in OpenMetadata
reaches from the source system into the warehouse.

**Read:** Airbyte Protocol spec (~30 min, high value), sync modes, incremental
append + dedup.

> Why ingestion comes *after* curation here, unlike a textbook pipeline: the
> agent understands the source from the catalog (Phase 1–2) before moving a byte,
> so by the time data lands it already has the glossary and grain context it needs
> to model it. The read path never sees an undocumented table.

---

### Phase 4 — The generation agent: use case → pipeline · ~2 weeks

**Goal:** `pi --agent data-engineer` takes the governed context from Phase 2 plus
one sentence of business intent, and produces a working medallion pipeline over
the `raw` layer Phase 3 landed.

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

Step 6 is what closes the circle and is worth stating plainly: **Phase 2's
output is Phase 4's input, and Phase 4's output flows back into Phase 2's
catalog.** The semantic layer is not a static document the agents consult — it
is a shared artifact they both maintain.

#### Grain is the whole difficulty

Everything else here is mechanical. Grain is where LLMs writing warehouse SQL
actually fail — `fct_order_items` at item grain versus `fct_orders` at order
grain, and revenue silently double-counted across the join. Three defences,
stacked:

1. **The glossary carries grain in prose.** "Measured at order grain, never item
   grain" came from the brief in Phase 2 and the agent reads it in step 1.
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
| the Phase 2 OpenMetadata read tools | glossary terms, table schemas, lineage |

Dagster needs almost no new work: `DbtProjectComponent` builds assets from
`manifest.json`, so new dbt models become Dagster assets automatically the moment
they compile. The only genuinely new Dagster asset is a Cube pre-aggregation
refresh (still unbuilt) — and generating pre-aggregations is out of scope for v1.
Say so rather than discovering it mid-demo.

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
- OpenMetadata shows column-level lineage from the raw source tables to the new
  marts, and the new mart columns carry the glossary terms the agent used.
- Human turns ≤ 3.
- **The comparison:** the same reviewer scores the agent's generated marts and
  cubes against the Stripe example's, on one rubric. Parity is the claim — the
  agent's output for an unfamiliar source should be indistinguishable in quality
  from the hand-built reference.

#### Where it will fail — plan for these

- **Grain**, as above. Mitigated, not eliminated.
- **A source with no incremental cursor** (a static dump, a snapshot table) never
  exercises schema drift and STATE — the interesting halves of the ingestion
  story. That is a property of the user's source, not a bug; note it when the
  connected source lacks a usable cursor.
- **Cube pre-aggregations and join-path tuning** are performance work with weak
  feedback signals. Out of scope for the agent; keep them hand-written.
- **Context bloat.** An unbounded `om_search_assets` or a raw `dbt build` log
  will eat the window mid-run. This is why every tool above is described as
  bounded.

#### Model and harness notes

pi speaks 15+ providers with mid-session switching, so the model is a config
choice — pin it in the package and record it in every eval result, because model
version is an experimental variable.

Default to **Claude Opus 5** (`claude-opus-5`) for both agents; the Phase 4
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

The Phase 2 eval checks structure. This one checks *behaviour*, so it has to
actually run the pipeline: reset the warehouse, hand the agent a goal, let it
build, then assert on the artifacts and the numbers. Run three or four distinct
goals against the same connected source — different measures, different grains,
different filter shapes — because a single golden path proves nothing about
generalisation. Score: build green, numbers match, human turns used, and a
judge's rubric score on the generated `schema.yml` descriptions and Cube
`description:` prose.

---

### Phase 5 — The analyst agent (the read path) · ~1.5 weeks

**Downstream of Phases 2 and 4, and the acceptance test for both.** Everything
this agent reads — glossary terms, classifications, marts, cubes — was produced
by the two write agents. Point it at the source the agent just built for: if it
can answer a business question over metadata and models that no human authored,
the two roles were automated for real.

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

### Phase 6 — Plug-and-play polish · ~1 week

The point of the whole scaffold: a stranger clones it, points it at their own
source, and gets a working platform. Make that literally true.

- **One command from cold** to every service up, on a new source, with the Stripe
  example deleted and nothing Stripe-shaped left in the default path.
- **A source/destination support matrix** — which OpenMetadata connectors and
  which Airbyte source/destination pairs are wired versus stubbed, so a new user
  knows immediately whether their stack is covered.
- **The write-agent guardrails from §10 turned on by default**: dry-run first,
  idempotent catalog writes, the scoped bot. A first run must be safe.
- A short write-up per tool: what it does, what broke, what you'd choose next
  time. Extend this doc's §8 table with real opinions.
- Stretch goals, pick one: a custom Airbyte connector with the low-code CDK;
  SPARQL-driven impact analysis as an agent tool; Cube pre-aggregation
  auto-tuning driven by the agent's own query log.

---

## 10. Practical warnings

- **RAM.** Airbyte (kind cluster) + OpenMetadata (server + Elasticsearch + MySQL/
  Postgres) + Dagster + Cube + Postgres is heavy. 32 GB is comfortable, 16 GB
  means running phases in isolation. Prefer PyAirbyte if constrained.
- **Don't build all six layers before testing any.** After each phase the
  scaffold should do something new on an arbitrary source. If a phase takes three
  weeks and the platform still can't do anything it couldn't before, you've lost
  the plot.
- **Version pinning.** OpenMetadata connector configs and Dagster's dbt
  integration both change across minor versions. Pin everything in
  `pyproject.toml` and note the versions here.
- **Bound your tool outputs.** Every tool the agent calls must cap its response
  size — the exact lesson OpenMetadata learned when they capped
  `search_metadata`. An unbounded catalog search will eat the context window.
- **Write descriptions as you go.** dbt `schema.yml`, Cube `description:`,
  OpenMetadata glossary. Retrofitting documentation for 40 models is the task
  that kills the project in week six. Every description is agent capability —
  and in the Stripe example specifically, it is the reference standard the
  curation and generation agents get graded against, so hand-writing it is not
  wasted work.
- **An agent with write access to the catalog is a different risk class.**
  Phases 2 and 4 hand an agent credentials that mutate governance metadata and
  the transformation repo. Three non-negotiables: every catalog write is
  idempotent and keyed by FQN (a non-idempotent retry duplicates your glossary),
  dry-run-then-apply is the default rather than an option, and the agent gets
  its own bot with its own RBAC scope instead of borrowing the ingestion bot's
  token. Demo the second run producing zero writes — that is the thing a
  governance audience actually wants to see.
- **Keep the example hand-built.** The Stripe example is the reference the agents'
  output is scored against, so a human writes it and the agents never "improve"
  it — the moment an agent edits the reference, every quality comparison becomes
  unfalsifiable. Keep it in `examples/`, separate from the template directories
  the agents fill for the user's own source.

---

## Sources

- [pi.dev](https://pi.dev/) · [badlogic/pi-mono — SDK docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/sdk.md) · [extensions docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) · [packages docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md)
- [OpenMetadata](https://github.com/open-metadata/OpenMetadata) · [MCP docs](https://docs.open-metadata.org/v1.12.x/how-to-guides/mcp) · [Introducing MCP in OpenMetadata](https://blog.open-metadata.org/introducing-the-model-context-protocol-mcp-in-openmetadata-e757385f4fb2) · [Announcing 1.13](https://blog.open-metadata.org/announcing-openmetadata-1-13-123d66609468) · [RDF & Ontologies overview](https://openmetadatastandards.org/rdf/overview/) · [OpenMetadataStandards repo](https://github.com/open-metadata/OpenMetadataStandards)
- [Airbyte](https://github.com/airbytehq/airbyte) · [Cube](https://github.com/cube-js/cube)
