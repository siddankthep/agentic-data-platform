# Stripe source variables — part of the Stripe *example*, not the scaffold.
#
# `make example-stripe` copies this file (and source_stripe.tf / connection.tf /
# outputs_stripe.tf) into ingestion/terraform/, where these variables are then
# declared. The ingestion Makefile always forwards TF_VAR_stripe_* from .env;
# Terraform silently ignores those env vars while the example is not installed
# (undeclared TF_VAR_ variables are dropped, not warned on), and picks them up
# once it is.

variable "stripe_account_id" {
  description = "Stripe account id (acct_...) to replicate."
  type        = string
}

variable "stripe_client_secret" {
  description = "Stripe restricted or secret API key. Use a test-mode key."
  type        = string
  sensitive   = true
}

variable "stripe_start_date" {
  description = "Replicate Stripe data created on or after this UTC timestamp."
  type        = string
  default     = "2017-01-25T00:00:00Z"
}

variable "stripe_lookback_window_days" {
  description = "Re-read this many days before the last cursor on incremental syncs, to catch late-mutating objects."
  type        = number
  default     = 0
}

variable "stripe_slice_range" {
  description = "Size in days of each incremental request window."
  type        = number
  default     = 365
}

variable "stripe_num_workers" {
  description = "Parallel workers the connector uses to fetch slices."
  type        = number
  default     = 10
}

variable "stripe_call_rate_limit" {
  description = "Requests per second ceiling. Stripe test mode allows 25; live mode allows 100."
  type        = number
  default     = 25
}
