# Stripe source + connection outputs — part of the Stripe example.
#
# The scaffold's ingestion/terraform/outputs.tf exposes only the destination.
# `make sync` reads connection_id, so it works only once the example (or your
# own source/connection) is installed.

output "source_id" {
  description = "Airbyte id of the Stripe source."
  value       = airbyte_source.stripe.source_id
}

output "connection_id" {
  description = "Airbyte id of the Stripe -> Postgres connection. `make sync` reads this to trigger a run."
  value       = airbyte_connection.stripe_to_postgres.connection_id
}
