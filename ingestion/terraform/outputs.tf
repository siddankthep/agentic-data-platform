output "source_id" {
  description = "Airbyte id of the Stripe source."
  value       = airbyte_source.stripe.source_id
}

output "destination_id" {
  description = "Airbyte id of the Postgres destination."
  value       = airbyte_destination.postgres.destination_id
}

output "connection_id" {
  description = "Airbyte id of the Stripe -> Postgres connection. `make sync` reads this to trigger a run."
  value       = airbyte_connection.stripe_to_postgres.connection_id
}
