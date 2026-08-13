-include ../.env
export

.PHONY: airbyte-up airbyte-down airbyte-creds airbyte-streams airbyte-versions \
        tf-init tf-plan tf-apply tf-destroy tf-fmt sync

# ---------------------------------------------------------------------------
# Airbyte ingestion
#
# Airbyte itself runs in a kind cluster managed by abctl, entirely outside the
# root compose project. Terraform owns everything *inside* it: the Stripe
# source, the Postgres destination and the connection between them.
# ---------------------------------------------------------------------------

TF := terraform -chdir=terraform

# Terraform reads credentials from the environment rather than a tfvars file, so
# .env stays the single place secrets live. `make airbyte-creds` populates the
# AIRBYTE_* half of it.
TF_ENV := \
	TF_VAR_airbyte_client_id="$(AIRBYTE_CLIENT_ID)" \
	TF_VAR_airbyte_client_secret="$(AIRBYTE_CLIENT_SECRET)" \
	TF_VAR_airbyte_workspace_id="$(AIRBYTE_WORKSPACE_ID)" \
	TF_VAR_stripe_account_id="$(STRIPE_ACCOUNT_ID)" \
	TF_VAR_stripe_client_secret="$(STRIPE_CLIENT_SECRET)" \
	TF_VAR_postgres_port="$(POSTGRES_PORT)" \
	TF_VAR_postgres_database="$(POSTGRES_DB)" \
	TF_VAR_postgres_username="$(POSTGRES_USER)" \
	TF_VAR_postgres_password="$(POSTGRES_PASSWORD)"

airbyte-up:
	abctl local install
	@echo "Airbyte is at http://localhost:8000. Run 'make airbyte-creds' next."

airbyte-down:
	abctl local uninstall

# Reads the client id/secret abctl generated and the default workspace id, and
# writes all three into .env.
airbyte-creds:
	../scripts/airbyte.sh creds

# The connector's own view of what it can replicate. Use this to check a stream
# name before adding it to local.stripe_streams in terraform/connection.tf.
airbyte-streams:
	../scripts/airbyte.sh streams

# Connector image tags this install runs; terraform/ pins these so plan-time
# validation matches sync-time behaviour.
airbyte-versions:
	../scripts/airbyte.sh versions

tf-init:
	$(TF) init

tf-plan:
	@$(TF_ENV) $(TF) plan

tf-apply:
	@$(TF_ENV) $(TF) apply

tf-destroy:
	@$(TF_ENV) $(TF) destroy

tf-fmt:
	$(TF) fmt -recursive

# Trigger the connection out of band and follow the job to completion. The
# schedule in terraform/ is 'manual' by default, so this is the normal way to
# pull Stripe data.
sync:
	../scripts/airbyte.sh sync
