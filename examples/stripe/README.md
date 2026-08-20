# Stripe example — the worked reference

A complete, **hand-built** data pipeline over Stripe: 21 dbt staging models, 2
intermediate, 11 marts; 11 Cube cubes + 2 views; an Airbyte Stripe → Postgres
`raw` connection; all of it running on the scaffold's Dagster graph.

This is the reference the agent roles are scored against — what "done" looks like
end-to-end. It is **not** the product. The scaffold ships empty; this example is
installed on demand and removed when you bring your own source.

> Keep this hand-built. It is the control the curation/generation agents are
> compared against — the moment an agent edits it, every quality comparison
> becomes unfalsifiable. See §10 of `docs/agentic-platform-project.md`.

## Layout

```
examples/stripe/
  transformation/models/{staging,intermediate,marts}/stripe/   dbt models + schema yml
  cube/{cubes,views}/                                          Cube cubes + views
  terraform/                                                    source + connection + their vars/outputs
  seed_stripe.py                                                seeds Stripe test-mode data
  docs/                                                         stripe-data-model.md, analytical-queries-guide.md
```

## Install / remove

```bash
make example-stripe     # copy the example into the working scaffold dirs
make dagster-refresh    # let Dagster re-read the dbt project + Airbyte catalog
# ... work with it ...
make example-clean      # remove exactly those files, restoring the empty scaffold
```

`make example-stripe` copies into:

| From | To |
|---|---|
| `transformation/models/*/stripe/` | `transformation/models/*/stripe/` |
| `cube/cubes/`, `cube/views/` | `cube_semantics/model/cubes/`, `.../views/` |
| `terraform/*.tf` | `ingestion/terraform/` |
| `seed_stripe.py` | `ingestion/seed_stripe.py` |

## Run it end to end

Assumes the platform is up (`make up && make migrate-up`) and Airbyte is
installed (`make airbyte-up && make airbyte-creds`).

```bash
make example-stripe
# set STRIPE_ACCOUNT_ID / STRIPE_CLIENT_SECRET in .env (test-mode key)
# .env already defaults AIRBYTE_SOURCE_NAME=stripe and the connection name
make tf-init && make tf-apply     # create the Airbyte source, destination, connection
make sync                         # land raw.* from Stripe
make dagster-refresh
make dagster-dbt                  # build staging -> intermediate -> marts
```

`python examples/stripe/seed_stripe.py` populates a Stripe test account with
representative objects first, if you don't already have data. See
`docs/stripe-data-model.md` for the model and `docs/analytical-queries-guide.md`
for example queries.
