provider "airbyte" {
  # Self-managed Airbyte serves the public API under /api/public/v1. Leaving
  # this unset would point the provider at Airbyte Cloud instead.
  server_url = var.airbyte_server_url

  # abctl provisions a single application whose credentials are readable with
  # `abctl local credentials`; `make airbyte-creds` copies them into .env.
  client_id     = var.airbyte_client_id
  client_secret = var.airbyte_client_secret

  # Without this the provider posts to Airbyte Cloud's token endpoint, gets the
  # login page back and fails with "failed to decode token response: invalid
  # character '<'". Self-managed mints tokens under its own API root.
  token_url = coalesce(var.airbyte_token_url, "${var.airbyte_server_url}/applications/token")
}
