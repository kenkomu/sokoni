# 3. No TC/C, no Saga — the chain event is the commit point

Date: 2026-09-09 · Status: accepted

## Context
Xu's digital wallet chapter works through Try-Confirm/Cancel and then Saga to
make a two-account transfer atomic across shards, each with real failure modes.

Our equivalent flow — user deposits USDC, receives an AUSD balance — decomposes
into an on-chain part (USDC in, swap to AUSD on Agora) that is atomic by
construction in one transaction, and a single off-chain part (credit the ledger).

## Decision
The indexer credits the ledger on observing the chain event, keyed by
`(tx_hash, log_index)` with a unique constraint. No coordinator, no compensating
transactions, no two-phase commit.

## Consequences
- A crash mid-flow is resolved by resuming from the checkpoint and reprocessing;
  the unique constraint makes that a no-op.
- We still get the full replayable audit trail that Xu builds event sourcing for.
- What we must handle instead is chain-specific and smaller: reorg rollback,
  dropped transactions, indexer lag. All live in one component.
- Reconciliation compares the ledger against on-chain balances continuously
  rather than against a nightly settlement file. **On unexplained drift the
  system halts trading rather than adjusting to match.**
