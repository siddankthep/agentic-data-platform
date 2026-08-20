variable "airbyte_server_url" {
  description = "Base URL of the Airbyte public API. For a local abctl install this is the abctl ingress plus /api/public/v1."
  type        = string
  default     = "http://localhost:8000/api/public/v1"
}

variable "airbyte_token_url" {
  description = "Override for the OAuth2 token endpoint. Defaults to <airbyte_server_url>/applications/token, which is correct for self-managed."
  type        = string
  default     = null
}

variable "airbyte_client_id" {
  description = "OAuth2 client id for the Airbyte API (`abctl local credentials`)."
  type        = string
  sensitive   = true
}

variable "airbyte_client_secret" {
  description = "OAuth2 client secret for the Airbyte API (`abctl local credentials`)."
  type        = string
  sensitive   = true
}

variable "airbyte_workspace_id" {
  description = "Workspace the source, destination and connection live in. abctl ships a single 'Default Workspace'."
  type        = string
}

# ---------------------------------------------------------------------------
# Source
#
# The scaffold declares no source of its own — the source is whatever you bring.
# A source connector (its own *.tf plus variables) is installed on top of this
# module: `make example-stripe` drops the Stripe source in, or you write your own
# source.tf against the airbyte_connector_configuration data source (see
# source.tf.example). Its variables live alongside it, not here.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Destination warehouse (Postgres by default)
# ---------------------------------------------------------------------------

variable "postgres_host" {
  description = <<-EOT
    Host as seen *from inside the Airbyte cluster*, not from your shell. The
    connector runs as a pod in abctl's kind cluster, so "localhost" would
    resolve to the pod itself. Reach the host through the kind bridge gateway
    (`docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}'`).
  EOT
  type        = string
  default     = "172.21.0.1"
}

variable "postgres_port" {
  description = "Host-published port of the compose Postgres, i.e. POSTGRES_PORT from .env, not the in-container 5432."
  type        = number
  default     = 5435
}

variable "postgres_database" {
  description = "Target database."
  type        = string
  default     = "ecom"
}

variable "postgres_schema" {
  description = "Schema that receives the typed source tables (the `raw` layer dbt reads)."
  type        = string
  default     = "raw"
}

variable "postgres_raw_data_schema" {
  description = "Schema for Airbyte's internal raw/state tables, kept out of the analytics schema."
  type        = string
  default     = "airbyte_internal"
}

variable "postgres_username" {
  description = "Postgres user."
  type        = string
  default     = "cube"
}

variable "postgres_password" {
  description = "Postgres password."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

variable "sync_schedule_type" {
  description = "Either 'manual' (trigger via `make sync`) or 'cron'."
  type        = string
  default     = "manual"

  validation {
    condition     = contains(["manual", "cron"], var.sync_schedule_type)
    error_message = "sync_schedule_type must be 'manual' or 'cron'."
  }
}

variable "sync_cron_expression" {
  description = "Quartz cron expression used when sync_schedule_type is 'cron'. Ignored otherwise."
  type        = string
  default     = "0 0 */6 * * ?"
}

variable "connection_status" {
  description = "'active' lets the schedule run; 'inactive' pauses the connection without destroying it."
  type        = string
  default     = "active"
}
