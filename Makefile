# Sokoni. Three toolchains, one entry point.
#
# Every target here is also a CI step, so a green `make ci` locally means a
# green pipeline. Flutter is not installed on every dev machine yet, so the
# Dart targets run through Docker.

DB_URL ?= postgres://sokoni:sokoni@localhost:5433/sokoni
RPC    ?= https://rpc.monad.xyz
DART   := docker run --rm -v "$(CURDIR)/mobile":/w -w /w dart:stable

.PHONY: help
help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## -- infra ------------------------------------------------------------------

.PHONY: up
up: ## Start Postgres and Redis
	docker compose up -d

.PHONY: down
down: ## Stop them
	docker compose down

.PHONY: migrate
migrate: ## Apply the schema
	docker compose exec -T postgres psql -U sokoni -d sokoni -v ON_ERROR_STOP=1 \
		-f - < backend/migrations/0001_init.sql

## -- backend ----------------------------------------------------------------

.PHONY: indexer
indexer: ## Run the chain follower
	cd backend && DATABASE_URL="$(DB_URL)" MONAD_RPC_HTTP="$(RPC)" go run ./cmd/indexer

.PHONY: go-check
go-check: ## gofmt + vet + race tests
	cd backend && test -z "$$(gofmt -l .)" || (gofmt -l . && echo "run: gofmt -w ." && exit 1)
	cd backend && go vet ./...
	cd backend && go test -race -count=1 ./...

## -- mobile -----------------------------------------------------------------

.PHONY: dart-fmt
dart-fmt: ## Format Dart (via Docker; no local Flutter needed)
	$(DART) dart format lib test

.PHONY: dart-check
dart-check: ## Check Dart formatting
	$(DART) dart format --output=none --set-exit-if-changed lib test

## -- contracts --------------------------------------------------------------

.PHONY: sol-check
sol-check: ## Format check, build, and test forked against Monad
	cd contracts && forge fmt --check
	cd contracts && forge build --sizes
	cd contracts && forge test -vv --fork-url $(RPC)

## -- everything -------------------------------------------------------------

.PHONY: ci
ci: go-check dart-check sol-check ## Everything CI runs
	@echo "all checks passed"
