# Developer entry points. Run `make help`.
SHELL        := /usr/bin/env bash
COMPOSE      := docker compose -f local/docker-compose.yml
LOCAL_CLIENT := $(COMPOSE) exec -T ch-s1-r1 clickhouse-client --user admin --password admin

.DEFAULT_GOAL := help

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---- Local cluster -----------------------------------------------------------------------------
up: ## Start the local 2x2 cluster + 3 Keepers and wait until healthy
	$(COMPOSE) up -d --wait

down: ## Stop the local cluster and delete its data
	$(COMPOSE) down -v

ps: ## Show local cluster containers
	$(COMPOSE) ps

logs: ## Tail ClickHouse server logs (NODE=ch-s1-r1)
	$(COMPOSE) logs -f $(or $(NODE),ch-s1-r1)

client: ## clickhouse-client as admin (CH_USER=dev_analyst CH_PASSWORD=dev to test a role)
	$(COMPOSE) exec ch-s1-r1 clickhouse-client --user $(or $(CH_USER),admin) --password $(or $(CH_PASSWORD),admin)

db-init: ## Apply access model then migrations to the local cluster
	CH_CLIENT="$(LOCAL_CLIENT)" ENV=local scripts/apply-access.sh
	CH_CLIENT="$(LOCAL_CLIENT)" scripts/migrate.sh

seed: ## Load sample data
	$(LOCAL_CLIENT) --multiquery < tests/seed.sql

test: ## Fresh cluster, init, seed, run security + data-flow tests
	$(MAKE) down up db-init seed
	tests/run.sh

reset: down up db-init seed ## Rebuild the local cluster from scratch with sample data

# ---- Schema ------------------------------------------------------------------------------------
migration: ## Create the next migration file: make migration NAME=add_orders_table
	scripts/new-migration.sh $(NAME)

migrate-status: ## Show applied / pending migrations on the local cluster
	CH_CLIENT="$(LOCAL_CLIENT)" scripts/migrate.sh status

# ---- Static checks (same as CI) ----------------------------------------------------------------
lint: ## Run all static checks
	pre-commit run --all-files
	conftest test --parser xml -p policies/clickhouse clickhouse/config.d
	terraform fmt -check -recursive terraform
	ansible-lint ansible

policy-test: ## Unit-test the OPA policies
	conftest verify -p policies/clickhouse
	conftest verify -p policies/terraform

.PHONY: help up down ps logs client db-init seed test reset migration migrate-status lint policy-test
