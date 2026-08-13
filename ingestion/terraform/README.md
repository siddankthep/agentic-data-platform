# Airbyte ingestion, as code

Terraform owns the Stripe → Postgres pipeline running inside the local Airbyte
install. Nothing here provisions Airbyte itself — `abctl` does that — but every
object *within* Airbyte is declared in this directory rather than clicked
together in the UI.

| File | What it declares |
| --- | --- |
| `providers.tf` | Airbyte API endpoint and OAuth2 credentials |
| `source_stripe.tf` | The Stripe source, pinned to connector 6.0.13 |
| `destination_postgres.tf` | The Postgres destination, pinned to connector 3.0.16 |
| `connection.tf` | The connection, its 21 selected streams and its schedule |

## First run

```bash
make airbyte-up       # abctl local install, if Airbyte isn't running yet
make airbyte-creds    # write AIRBYTE_* credentials into .env
make up               # the compose Postgres the destination writes to
make tf-init
make tf-apply
make sync             # trigger a run and follow it
```

## Provider notes

Two things about this provider are easy to trip over:

**Generic resources.** Provider 1.1 removed the typed per-connector resources
(`airbyte_source_stripe` and friends). Sources and destinations are now
`airbyte_source` / `airbyte_destination` taking a JSON `configuration` blob. The
`airbyte_connector_configuration` data source resolves a connector *name* to its
definition id, fetches the connector's JSONSchema and validates the config at
plan time — so a mistyped key fails during `terraform plan` rather than at sync
time. It also keeps secrets in a separate `configuration_secrets` argument so
plan output stays readable instead of being wholly redacted.

**Token URL.** Self-managed Airbyte mints tokens under its own API root. Without
the explicit `token_url` in `providers.tf`, the provider posts to Airbyte
Cloud's endpoint, gets an HTML login page back, and fails with the unhelpful
`failed to decode token response: invalid character '<'`.

## Networking

The Postgres destination connector runs as a pod inside abctl's kind cluster.
`localhost` there is the pod, so `postgres_host` points at the kind bridge
gateway instead:

```bash
docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}'   # 172.21.0.1
```

and `postgres_port` is the *host-published* port from `.env` (5435), not the
5432 the container listens on internally.

## Changing what is replicated

`local.stripe_streams` in `connection.tf` selects 21 of the connector's 47
streams. Check a name against the live catalog before adding it — an unknown
stream fails at apply:

```bash
make airbyte-streams
```

Every selected stream has a source-defined cursor and primary key, so
`incremental_deduped_history` needs no explicit `cursor_field` or `primary_key`;
the destination keeps one row per Stripe object id.

## Connector upgrades

`connector_version` is pinned in both `source_stripe.tf` and
`destination_postgres.tf` so plan-time validation matches what actually runs.
When you upgrade a connector in Airbyte, bump the matching `local` value:

```bash
make airbyte-versions
```

## State

State is local and gitignored — it contains the Stripe key and the Postgres
password in cleartext. The `.terraform.lock.hcl` provider lock *is* tracked. If
this ever becomes more than a local project, move state to a remote backend
before sharing it.
