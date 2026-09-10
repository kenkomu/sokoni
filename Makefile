# Sokoni. Three toolchains, one entry point.
#
# Every target here is also a CI step, so a green `make ci` locally means a
# green pipeline.
#
# Requires: Go 1.26+, Flutter 3.47+ (~/develop/flutter/bin on PATH),
# Foundry >= 1.8 (older releases have no Monad execution support).

DB_URL ?= postgres://sokoni:sokoni@localhost:5433/sokoni
RPC    ?= https://rpc.monad.xyz

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
dart-fmt: ## Format Dart
	cd mobile && dart format lib test

.PHONY: dart-check
dart-check: ## Format check, analyze, test
	cd mobile && dart format --output=none --set-exit-if-changed lib test
	cd mobile && flutter analyze
	cd mobile && flutter test

.PHONY: fixture-sync
fixture-sync: ## Copy the WebAuthn vector from contracts to mobile
	cp contracts/test/fixtures/webauthn_vector.json mobile/test/fixtures/webauthn_vector.json

## -- contracts --------------------------------------------------------------

.PHONY: sol-check
sol-check: ## Format check, build, and test under Monad execution rules
	cd contracts && forge fmt --check
	cd contracts && forge build --sizes
	cd contracts && forge test -vv

.PHONY: userop-vector
userop-vector: ## Regenerate the userOp vector shared with the Go backend
	cd contracts && forge script script/GenUserOpVector.s.sol

.PHONY: deploy-factory
deploy-factory: ## Deploy SokoniAccountFactory (needs PRIVATE_KEY, ENTRYPOINT)
	cd contracts && forge script script/DeployFactory.s.sol --rpc-url "$(RPC)" --broadcast

.PHONY: deploy-paymaster
deploy-paymaster: ## Deploy, fund and stake SokoniPaymaster (needs PRIVATE_KEY, ENTRYPOINT, PAYMASTER_SIGNER)
	cd contracts && forge script script/DeployPaymaster.s.sol --rpc-url "$(RPC)" --broadcast

.PHONY: gateway
gateway: ## Run the phone's API (needs the ERC-4337 and gateway settings in .env.example)
	cd backend && go run ./cmd/gateway

.PHONY: onboard
onboard: ## Drive one sponsored passkey operation against a live chain and print each step
	cd backend && go run ./cmd/onboard $(ARGS)

## -- everything -------------------------------------------------------------

.PHONY: ci
ci: go-check dart-check sol-check ## Everything CI runs
	@echo "all checks passed"
