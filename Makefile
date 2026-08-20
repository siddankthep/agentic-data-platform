-include .env
export

.PHONY: init up down logs psql migrate-up migrate-down migrate-create migrate-force reset fix-perms \
        dagster-dev dagster-materialize dagster-dbt dagster-check dagster-refresh \
        $(INGESTION_TARGETS)

COMPOSE_FILE   := docker-compose.yml
# The compose file lives in cube_mcp/, so compose would otherwise pick up
# cube_mcp/.env (Cube's own config) for substitution instead of ours.
COMPOSE        := docker compose $(if $(wildcard .env),--env-file .env,) -f $(COMPOSE_FILE)
MIGRATIONS_DIR := ./db/migrations

# Run the cube container as the invoking user so files it writes into the
# cube_mcp/ bind mount stay editable on the host.
export DOCKER_UID := $(shell id -u)
export DOCKER_GID := $(shell id -g)

POSTGRES_HOST     ?= localhost
POSTGRES_PORT     ?= 5432
POSTGRES_USER     ?= cube
POSTGRES_PASSWORD ?= cube
POSTGRES_DB       ?= ecom

DATABASE_URL := postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=disable

init:
	go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@v4.18.2
	cp -n .env.example .env 2>/dev/null || true
	@echo "Setup complete! Run 'make up && make migrate-up', then 'make sync' to land Stripe data."

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

psql:
	$(COMPOSE) exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

# Reclaim any root-owned files left behind by a container that ran as root
# (e.g. `docker compose up` invoked directly, without DOCKER_UID exported).
# Uses a throwaway root container so no host sudo is needed.
fix-perms:
	docker run --rm -v "$(CURDIR)/cube_mcp:/mnt" alpine:3 chown -R $(DOCKER_UID):$(DOCKER_GID) /mnt
	@echo "cube_mcp/ is owned by $(DOCKER_UID):$(DOCKER_GID) again."

migrate-up:
	migrate -path "$(MIGRATIONS_DIR)" -database "$(DATABASE_URL)" up

migrate-down:
	migrate -path "$(MIGRATIONS_DIR)" -database "$(DATABASE_URL)" down 1

migrate-create:
	@if [ -z "$(name)" ]; then echo "Usage: make migrate-create name=<migration_name>"; exit 1; fi
	migrate create -ext sql -dir $(MIGRATIONS_DIR) -seq $(name)

migrate-force:
	@if [ -z "$(version)" ]; then echo "Usage: make migrate-force version=<n>"; exit 1; fi
	migrate -path "$(MIGRATIONS_DIR)" -database "$(DATABASE_URL)" force $(version)

# Blow away the volume and rebuild from scratch. Provisions schemas only; run
# `make sync` afterwards to land Stripe data into `raw` via Airbyte.
reset:
	$(COMPOSE) down -v
	$(MAKE) up
	@until $(COMPOSE) exec -T postgres pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB) >/dev/null 2>&1; do sleep 1; done
	$(MAKE) migrate-up
	@echo "Schemas ready. Run 'make sync' to land Stripe data via Airbyte."

# ---------------------------------------------------------------------------
# Airbyte ingestion — delegated to ingestion/Makefile
#
# Airbyte itself runs in a kind cluster managed by abctl, entirely outside this
# compose project. Terraform owns everything *inside* it: the Stripe source, the
# Postgres destination and the connection between them. See ingestion/Makefile
# for the actual recipes; this just forwards so `make sync` etc. still work
# from the repo root.
# ---------------------------------------------------------------------------

INGESTION_TARGETS := airbyte-up airbyte-down airbyte-creds airbyte-streams airbyte-versions \
                      tf-init tf-plan tf-apply tf-destroy tf-fmt sync

$(INGESTION_TARGETS):
	$(MAKE) -C ingestion $@

# ---------------------------------------------------------------------------
# Dagster orchestration
#
# Unifies the Airbyte connection and the dbt DAG into one asset graph. Every
# definition is a defs.yaml under orchestration/defs — see that directory.
#
# DAGSTER_HOME must be an absolute path and must exist, otherwise `dagster dev`
# stores run history in a temp dir and forgets it on exit (which also means
# declarative automation has no history to reason about).
# ---------------------------------------------------------------------------

export DAGSTER_HOME := $(CURDIR)/.dagster_home

dagster-dev: $(DAGSTER_HOME)
	uv run dagster dev

# An empty dagster.yaml is Dagster's way of saying "defaults are intentional";
# without the file it warns on every command.
$(DAGSTER_HOME):
	@mkdir -p $(DAGSTER_HOME)
	@touch $(DAGSTER_HOME)/dagster.yaml

# Build the whole graph once, by hand: Airbyte sync -> staging -> marts.
# Automation normally does this (see the automation_condition in each
# defs.yaml); this is the manual escape hatch.
dagster-materialize: $(DAGSTER_HOME)
	uv run dagster asset materialize --select '*' -m orchestration.definitions

# dbt only — skips the Airbyte sync, so it neither hits the Stripe API nor
# waits on a connector pod.
dagster-dbt: $(DAGSTER_HOME)
	uv run dagster asset materialize --select 'kind:dbt' -m orchestration.definitions

# Static validation of every component: resolves each defs.yaml, builds the
# manifest and checks asset keys line up. Fast, and the thing to run in CI.
dagster-check:
	uv run dg check defs

# Re-pull the state each component caches under
# orchestration/defs/.local_defs_state: the Airbyte connection catalog, and a
# full COPY of the dbt project.
#
# Run this after editing dbt models or changing Airbyte streams. The copy is why
# it is needed — Dagster runs dbt against the snapshot, not against
# transformation/, so without a refresh you are orchestrating stale SQL and the
# asset graph still shows models you deleted.
dagster-refresh: $(DAGSTER_HOME)
	uv run dg utils refresh-defs-state
