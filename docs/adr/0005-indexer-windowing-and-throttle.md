# 5. The indexer fetches windows concurrently, behind a token bucket

Date: 2026-09-09 · Status: accepted

## Context
The first indexer did `getBlockNumber` then `getBlock`, serially, per block. It
ran at **1.15 blocks/s against a chain producing 3.3 blocks/s** — it fell behind
forever and would never catch up.

Measured against `https://rpc.monad.xyz` on 2026-09-09:

| call                      | latency |
|---------------------------|---------|
| `getBlockNumber`          | 1149 ms |
| `getBlock` × 1            |  441 ms |
| `getBlock` × 16 concurrent|  448 ms |
| `getBlock` × 32 concurrent|  813 ms |

Round-trip latency dominates; concurrency up to ~16 is essentially free.

Fetching windows concurrently reached 38.5 blocks/s and was then killed by the
provider: `-32007  50/second request limit reached`. Note the real ceiling is
**50/s**, not the 25 rps the Monad docs quote.

## Decision
Fetch a window of 16 blocks per round trip; refresh the head only when caught
up; checkpoint once per window rather than per block (replay is idempotent).
Route every chain read through a token bucket, default 20 rps, with exponential
backoff and full jitter on rate-limit errors.

## Consequences
- Sustains **~22 blocks/s**, 6.6× the chain rate — enough headroom to backfill.
  Measured catching up from 421 blocks behind to 19 in 45 seconds.
- A rate limit now pauses the indexer instead of crashing it. A crash-looping
  follower falls further behind on every restart, which is strictly worse.
- The 20 rps cap leaves room for the gateway and treasury on the same endpoint.
  This is the "global RPC egress" bucket from the system design.
- **A paid RPC endpoint is a launch requirement, not an optimisation** — the
  write path alone peaks near the free ceiling before any market data.
