# Stripe data model

How Stripe billing data gets from the API into business-ready marts, and
what each mart means. Read this once; it should be enough to answer "where
does metric X come from" without opening the SQL.

## Data flow

```
Stripe API
   │  source-stripe (Airbyte), 21 streams, incremental_deduped_history
   ▼
raw.*            Postgres, schema "raw". Verbatim Stripe objects (jsonb kept
                  for nested fields), one row per object id. Never queried
                  directly -- see ingestion/terraform/connection.tf.
   │  dbt: staging/stripe/stg_stripe__*.sql
   ▼
staging.*        1:1 with raw. Renamed columns, epoch → timestamp, cents →
                  major units, soft-deletes filtered out. No joins.
   │  dbt: intermediate/stripe/int_stripe__*.sql
   ▼
intermediate.*   Where MRR gets defined once (subscription items × prices,
                  normalized to a monthly figure). Views, not queried
                  outside dbt.
   │  dbt: marts/stripe/{dim,fct}_*.sql
   ▼
marts.*          Business grain. Tables. This is what Cube, BI tools, and
                  the agent should query.
```

Run it: `cd transformation && dbt build --select staging.stripe
intermediate.stripe marts.stripe`. Sources, models, and 74 tests
(uniqueness, not-null, referential integrity) are declared in the
`_stripe__*.yml` file next to each layer's models.

## The marts

| Mart | Grain | Answers |
|---|---|---|
| `dim_customers` | 1 row / customer | Who is this customer, are they an active subscriber, what's their lifetime value? |
| `dim_products` | 1 row / product | What do we sell, at what monthly-normalized price? |
| `dim_promotions` | 1 row / promo code or coupon | What discounts exist and how much have they been redeemed? |
| `fct_subscriptions` | 1 row / subscription (current state) | Who's subscribed, to what, and how much MRR do they contribute? |
| `fct_invoices` | 1 row / invoice | What was billed, what's still owed (AR)? |
| `fct_invoice_line_items` | 1 row / invoice line | What made up an invoice? |
| `fct_charges` | 1 row / charge attempt | Payment volume, success/decline rate, net-of-fee proceeds |
| `fct_refunds` | 1 row / refund | Refund volume and reasons |
| `fct_disputes` | 1 row / dispute | Chargeback exposure |
| `fct_payouts` | 1 row / payout | Money that left the Stripe balance for the bank |
| `fct_balance_transactions` | 1 row / ledger entry | Reconciliation: gross, fee, net across every balance-moving event |

## Metrics defined once

- **MRR** — `int_stripe__subscription_items_priced.mrr_amount`, normalized
  across billing intervals (day/week/month/year) to a monthly figure, summed
  per subscription in `fct_subscriptions.mrr`. Sum `mrr` filtered to
  `is_active` for total current MRR — don't derive it from invoices, which
  mixes one-off and recurring charges.
- **Lifetime value** — `dim_customers.lifetime_value`, sum of `amount_captured`
  across succeeded charges (gross, before refunds). `lifetime_refunded` is
  tracked separately so you can net them yourself depending on the question.
- **Net proceeds** — `fct_charges.net_amount` / `fct_balance_transactions.net`,
  amount after Stripe's processing fee. This is what actually hits the
  account balance, independent of what the invoice or subscription says was
  owed.

## Known data caveats

- **MRR is a snapshot, not a movement bridge.** There's no plan-change
  history in this dataset (Stripe won't backdate `created`, and the seed
  script doesn't use test clocks — see `ingestion/seed_stripe.py`), so there's
  no reliable way to build a new/expansion/contraction/churn waterfall yet.
  `fct_subscriptions.mrr` reflects each subscription's current items only.
- **`fct_invoice_line_items` has weak join keys.** `price_id` and
  `subscription_id` come back null on most lines in this account — Stripe
  didn't backfill them from the parent invoice. Use `description` for
  human-readable line detail; use `fct_subscriptions.mrr` for product/plan
  revenue splits instead of trying to join this table to `dim_products`.
- **`fct_payouts`, `credit_notes`, `checkout_sessions` are empty.** Staged
  and mart-ready, but this test account hasn't triggered any payouts,
  credit notes, or Checkout sessions — the tables just have zero rows today.
- **`stg_stripe__events` and `stg_stripe__setup_intents` are staged but not
  modeled into marts.** `events` is Stripe's own audit trail (useful for
  ad hoc "what happened to object X" lineage questions); `setup_intents`
  tracks saved payment methods, not billing activity.
- **Single currency.** Everything in this account is `usd`, so amounts
  aren't currency-converted anywhere. Add that if a second currency shows up.

## Where this fits in the bigger platform

Per `docs/agentic-platform-project.md` §3: Cube should point at `marts.*`,
never `staging.*` — joins and grain are already solved here, so the
semantic layer doesn't need defensive joins. `cube_semantics/model/` is the
next thing to update to read from these tables instead of the seeded Olist
data.
