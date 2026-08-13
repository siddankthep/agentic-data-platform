# Pinned to the connector version this Airbyte install actually runs, so the
# plan-time schema validation below matches what executes at sync time. Check
# with `make airbyte-connector-versions` before bumping.
locals {
  stripe_connector_version = "6.0.13"
}

# Resolves source-stripe to its definition_id, pulls the connector's JSONSchema
# spec and validates the config against it during `terraform plan` — so a typo'd
# key fails before anything is created in Airbyte.
data "airbyte_connector_configuration" "stripe" {
  connector_name     = "source-stripe"
  connector_version  = local.stripe_connector_version
  connector_registry = "oss"

  configuration = {
    account_id           = var.stripe_account_id
    start_date           = var.stripe_start_date
    lookback_window_days = var.stripe_lookback_window_days
    slice_range          = var.stripe_slice_range
    num_workers          = var.stripe_num_workers
    call_rate_limit      = var.stripe_call_rate_limit
  }

  # Kept separate from `configuration` so the API key stays redacted in plan
  # output instead of marking the whole block sensitive.
  configuration_secrets = {
    client_secret = var.stripe_client_secret
  }
}

resource "airbyte_source" "stripe" {
  name          = "Stripe"
  workspace_id  = var.airbyte_workspace_id
  definition_id = data.airbyte_connector_configuration.stripe.definition_id
  configuration = data.airbyte_connector_configuration.stripe.configuration_json
}
