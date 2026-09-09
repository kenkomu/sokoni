# 1. The chain is the sequencer; we are a broker, not an exchange

Date: 2026-09-09 · Status: accepted

## Context
Alex Xu's stock exchange chapter builds a matching engine, a sequencer stamping
every order with a monotonic ID, and an mmap event store on a single machine —
all to obtain determinism and microsecond latency.

We are building on Monad, where `(block, txIndex, logIndex)` is already a total
order agreed by consensus, the event log is already immutable and replayable,
and an audited on-chain CLOB already exists.

## Decision
We do not build a matching engine, a sequencer, or an event store. We build the
components Xu puts *around* the matching core: client gateway, order manager,
market data publisher, reporter.

## Consequences
- Event sourcing is not a choice, it is the only available model. All read state
  is a projection of chain events and is rebuildable by replay.
- Scope drops from ~34 weeks to ~34 days, which is the actual constraint.
- We inherit chain concerns Xu does not have: reorgs, dropped transactions,
  finality. These are handled in the indexer (see ADR 3).
- We cannot offer sub-block latency. Acceptable: §2 of the system design shows
  the biometric prompt costs more than the block time.
