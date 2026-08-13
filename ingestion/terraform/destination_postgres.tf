locals {
  postgres_connector_version = "3.0.16"
}

data "airbyte_connector_configuration" "postgres" {
  connector_name     = "destination-postgres"
  connector_version  = local.postgres_connector_version
  connector_registry = "oss"

  configuration = {
    host            = var.postgres_host
    port            = var.postgres_port
    database        = var.postgres_database
    schema          = var.postgres_schema
    raw_data_schema = var.postgres_raw_data_schema

    # The compose Postgres terminates plaintext on the docker bridge; there is
    # no certificate to verify against on a loopback hop.
    ssl      = false
    ssl_mode = { mode = "disable" }
  }

  configuration_secrets = {
    username = var.postgres_username
    password = var.postgres_password
  }
}

resource "airbyte_destination" "postgres" {
  name          = "Postgres (ecom)"
  workspace_id  = var.airbyte_workspace_id
  definition_id = data.airbyte_connector_configuration.postgres.definition_id
  configuration = data.airbyte_connector_configuration.postgres.configuration_json
}
