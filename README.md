# Sokoni

A passkey-native, AUSD-denominated mobile trading app on Monad.
Built for the **Metropolis** hackathon (Onchain Finance & Trading track, Agora bounty).
Submission deadline **13 Oct 2026**.

> *Sokoni* — Swahili, "at the market". Working name, easy to change.

## The idea in one line

Your cash balance is AUSD, your signature is your fingerprint, and the stable leg
settles at exactly 1:1 with zero fees and zero slippage.

## Architecture in one paragraph

Monad is the sequencer and the matching engine — `(block, txIndex, logIndex)` is
already a total order, and an audited on-chain CLOB already exists. So we build
the parts *around* a matching core: a gateway, an order service, a market-data
plant, and a ledger. All read state is a projection of chain events, rebuildable
by replay. Users trade against AUSD on a permissionless venue; a single
whitelisted treasury address uses Agora Instant Settlement for AUSD⇄USDC.

Full design: `docs/` and the published system design. Decisions: `docs/adr/`.

## Why one indexer

If every client polled the chain we would need ~3,000 rps against a 50 rps
ceiling. One follower holds the only chain read subscription and fans out over
WebSocket, so chain load stays flat at the block rate no matter how many users
we have. Read amplification O(N) → O(1). This is the central structural decision.

## Layout

```
packages/chain     verified Monad addresses, ABIs, throttled RPC client
packages/shared    Money (never a float), Snowflake ids
services/indexer   the spine: follows blocks, checkpoints, handles reorgs
services/gateway   REST + WS edge (next)
contracts/         passkey account + validator (next)
apps/mobile/       React Native client (next)
db/schema.sql      projections; safe to drop and replay
docs/adr/          why things are the way they are
```

## Running it

```bash
npm install
docker compose up -d                 # postgres :5433, redis :6380
npm run db:migrate                   # or: docker compose exec -T postgres psql -U sokoni -d sokoni < db/schema.sql
cp .env.example .env

DATABASE_URL=postgres://sokoni:sokoni@localhost:5433/sokoni \
MONAD_RPC_HTTP=https://rpc.monad.xyz \
  npm run indexer
```

The indexer cold-starts at the chain head. To backfill, set
`INDEXER_START_BLOCK` to a block number.

## Measured, not assumed

Everything below was read from mainnet on 2026-09-09, not taken from docs:

| | |
|---|---|
| Monad block time | **0.302 s** (mean over 1,000 blocks) |
| Public RPC real ceiling | **50/s** (docs say 25 rps) |
| `getBlock` ×16 concurrent | 448 ms — same cost as one |
| Indexer sustained | **~22 blocks/s**, 6.6× chain rate |
| Agora AUSD/USDC | price exactly 1e18, both fees 0, not paused |
| Agora reserves | 9,787,010 AUSD / 1,017,848 USDC |
| `APPROVED_SWAPPER` holders | 71 — the whitelist is real and closed |

## Known constraints

- **Agora is permissioned.** The treasury address must be whitelisted by Agora.
  Until then, use the Sepolia CTK/AUSD adapter. See ADR 4.
- **A paid RPC endpoint is required**, not optional. See ADR 5.
- **Foundry ≥ 1.8.0** is needed for Monad execution support. Check `forge --version`.
