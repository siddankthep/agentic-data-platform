# The scaffold's Terraform declares only the destination warehouse. A source and
# a connection are installed on top of it (see source.tf.example /
# connection.tf.example, or `make example-stripe`), and they contribute the
# `source_id` and `connection_id` outputs that `make sync` relies on.

output "destination_id" {
  description = "Airbyte id of the Postgres destination warehouse."
  value       = airbyte_destination.postgres.destination_id
}
