# The Stripe connector exposes 47 streams; most are irrelevant to an ecommerce
# warehouse (Issuing cards, Connect persons, file links). This is the subset the
# semantic layer can actually build on, and it matches the objects
# ingestion/seed_stripe.py creates in test mode.
#
# Every stream below has a source-defined cursor and primary key, so
# incremental_deduped_history needs no explicit cursor_field / primary_key:
# Airbyte reads them from the catalog and the destination keeps one row per
# Stripe object id. Verify names against a fresh catalog with
# `make airbyte-streams` before adding to this list — a name that does not exist
# in the source fails at apply time.
locals {
  stripe_streams = [
    # Customers and subscription lifecycle
    "customers",
    "subscriptions",
    "subscription_items",
    "plans",

    # Catalog
    "products",
    "prices",

    # Billing documents
    "invoices",
    "invoice_line_items",
    "invoice_items",
    "credit_notes",

    # Money movement
    "payment_intents",
    "charges",
    "refunds",
    "disputes",
    "payouts",
    "balance_transactions",

    # Funnel and promotions
    "checkout_sessions",
    "setup_intents",
    "coupons",
    "promotion_codes",

    # Audit trail
    "events",
  ]
}

resource "airbyte_connection" "stripe_to_postgres" {
  name           = "Stripe -> Postgres (raw)"
  source_id      = airbyte_source.stripe.source_id
  destination_id = airbyte_destination.postgres.destination_id

  status = var.connection_status

  # Land everything in the destination's configured schema (var.postgres_schema)
  # rather than mirroring Stripe's namespace, so tables are raw.customers etc.
  namespace_definition = "destination"
  prefix               = ""

  # Stripe adds fields to its objects regularly. Propagating columns keeps the
  # warehouse current without a manual schema refresh; a genuinely breaking
  # change still pauses the connection.
  non_breaking_schema_updates_behavior = "propagate_columns"

  schedule = {
    schedule_type = var.sync_schedule_type
    # The API rejects a cron_expression on a manual schedule, so this collapses
    # to null unless cron is actually selected.
    cron_expression = var.sync_schedule_type == "cron" ? var.sync_cron_expression : null
  }

  configurations = {
    streams = [
      for name in local.stripe_streams : {
        name      = name
        sync_mode = "incremental_deduped_history"
      }
    ]
  }
}
