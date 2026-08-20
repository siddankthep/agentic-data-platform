# Cube semantic layer — the contract the generation agent fills

Empty in the scaffold. The generation agent (Phase 4) writes cubes and views here
over the marts it built; `make example-stripe` installs the hand-built Stripe
example (11 cubes + 2 views) as the reference.

`CUBEJS_SCHEMA_PATH=model`, so Cube loads everything under this directory.

## Layout

```
model/
  cubes/   one cube per mart. Measures (with aggregation type), dimensions,
           joins declared WITH cardinality (one_to_many, ...).
  views/   consumer-facing bundles of members from several cubes. This is what
           the analyst agent is exposed to, not raw cubes.
```

## Rules the layer encodes

- **Cubes point at `silver_marts`**, the conformed, correct-grain tables dbt
  builds — never at staging or raw.
- **Joins carry cardinality**, so Cube picks the join path and avoids fan-out
  double counting. This is the semantic-layer half of the grain defence (the dbt
  `unique` test is the other half).
- **Measures carry their aggregation type**, so Cube can refuse to average an
  average.
- **Views are the governed surface.** Expose views to the agent; keep raw cubes
  internal.
- **`title:` and `description:` are prompt engineering.** `/v1/meta` turns them
  straight into the tool schema the analyst agent reads, so write them as prose.

See the Stripe example's `revenue_overview.yml` for a view with a `GRAIN WARNING`
block — the pattern for carrying a grain caveat into the semantic layer.
