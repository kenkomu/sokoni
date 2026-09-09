# Sokoni

[![backend](https://github.com/kenkomu/sokoni/actions/workflows/backend.yml/badge.svg)](https://github.com/kenkomu/sokoni/actions/workflows/backend.yml)
[![mobile](https://github.com/kenkomu/sokoni/actions/workflows/mobile.yml/badge.svg)](https://github.com/kenkomu/sokoni/actions/workflows/mobile.yml)
[![contracts](https://github.com/kenkomu/sokoni/actions/workflows/contracts.yml/badge.svg)](https://github.com/kenkomu/sokoni/actions/workflows/contracts.yml)
[![security](https://github.com/kenkomu/sokoni/actions/workflows/security.yml/badge.svg)](https://github.com/kenkomu/sokoni/actions/workflows/security.yml)

A passkey-native, AUSD-denominated mobile trading app on Monad.
Built for the **Metropolis** hackathon — Onchain Finance & Trading track, Agora bounty.
Submission deadline **13 Oct 2026**.

> *Sokoni* — Swahili, "at the market". Working name, easy to change.

## The idea in one line

Your cash balance is AUSD, your signature is your fingerprint, and the stable
leg settles at exactly 1:1 with zero fees and zero slippage.

## Architecture in one paragraph

Monad is the sequencer and the matching engine — `(block, txIndex, logIndex)` is
already a total order agreed by consensus, and an audited on-chain order book
already exists. So we build the components that sit *around* a matching core: a
gateway, an order service, a market-data plant, and a ledger. All read state is
a projection of chain events and is rebuildable by replay. Users trade against
AUSD on a permissionless venue; a single whitelisted treasury address uses Agora
Instant Settlement for AUSD⇄USDC.

Decisions and their reasoning: [`docs/adr/`](docs/adr/).

## Why exactly one indexer

If every client polled the chain we would need ~3,000 rps against a 50 rps
ceiling. One follower holds the only chain read subscription and fans out over
WebSocket, so chain load stays flat at the block rate no matter how many users
we have. Read amplification O(N) → O(1). This is the central structural decision.

## Stack

| | |
|---|---|
| Mobile | Flutter 3.6 · Riverpod · passkeys/local_auth |
| Backend | Go 1.26 · pgx · Postgres 18 · Redis 8 |
| Contracts | Foundry (needs ≥ 1.8.0 for Monad execution) |
| Chain | Monad mainnet 143 / testnet 10143 |

## Layout

```
backend/
  cmd/{indexer,gateway,treasury,reconciler}   service entrypoints
  internal/chain        verified addresses, batching RPC client, token bucket
  internal/money        Amount: big.Int units + scale, never a float
  internal/id           Snowflake ids
  internal/indexer      the spine: windowed follower, checkpoints, reorgs
  internal/store        Postgres projections
  migrations/           schema; projections are safe to drop and replay
mobile/
  lib/core              config, Money (mirrors the Go type)
  lib/data              api client, market stream with gap detection
  lib/design            theme; bid/ask colours separate from the accent
  lib/features          onboarding, markets, trade, portfolio, settings
contracts/              passkey account + P256 validator
docs/adr/               why things are the way they are
```

## Running it

`make help` lists everything. `make ci` runs exactly what CI runs, so green
locally means green in the pipeline.

```bash
docker compose up -d                       # postgres :5433, redis :6380
docker compose exec -T postgres psql -U sokoni -d sokoni < backend/migrations/0001_init.sql

cd backend
DATABASE_URL=postgres://sokoni:sokoni@localhost:5433/sokoni \
MONAD_RPC_HTTP=https://rpc.monad.xyz \
  go run ./cmd/indexer

go test ./...
```

The indexer cold-starts at the chain head. Set `INDEXER_START_BLOCK` to backfill.

## Measured, not assumed

Read from mainnet on 2026-09-09, not taken from documentation:

| | |
|---|---|
| Monad block time | **0.302 s** (mean over 1,000 blocks) |
| Public RPC real ceiling | **50/s** — the docs say 25 rps |
| `eth_blockNumber` | 1149 ms — never put it in a tight loop |
| `getBlock` ×16 batched | 448 ms — same cost as one |
| Indexer sustained | **~20 blocks/s**, 6× chain rate |
| Agora AUSD/USDC | price exactly 1e18, both fees 0, not paused |
| Agora reserves | 9,787,010 AUSD / 1,017,848 USDC |
| `APPROVED_SWAPPER` holders | 71 — the whitelist is real and closed |

## Known constraints

- **Agora is permissioned.** The treasury address must be whitelisted by Agora.
  Until then the Sepolia CTK/AUSD adapter stands in. See ADR 4.
- **A paid RPC endpoint is a launch requirement**, not an optimisation. See ADR 5.
- **Flutter is not installed** on this machine yet — needed before Phase 2.
  Until then `make dart-fmt` / `make dart-check` run the formatter via Docker.
- **Foundry is 1.7.1**; Monad execution support needs ≥ 1.8.0.
- **Dart SDK is pinned ≥3.7** on purpose: the formatter only uses tall style at
  3.7+, and a lower constraint made local and CI formatters disagree.
