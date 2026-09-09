/**
 * The indexer — the spine of the system.
 *
 * This process holds THE ONLY chain read subscription in the whole platform.
 * §2 of the system design: if every client polled the chain we'd need ~3,000
 * rps against a 25 rps ceiling. One follower keeps chain load flat at the block
 * rate no matter how many users we have. Everything else reads Postgres/Redis.
 *
 * Guarantees it must keep:
 *  - Ordered. Blocks are applied strictly in sequence.
 *  - Idempotent. Reprocessing a block writes nothing new (unique constraints).
 *  - Reorg-aware. A parentHash mismatch rolls back rather than corrupting state.
 *  - Resumable. Crash and restart continues from the checkpoint.
 *
 * PERFORMANCE — measured against https://rpc.monad.xyz, 2026-09-09:
 *   getBlockNumber        1149 ms   <- surprisingly expensive
 *   getBlock (1)           441 ms
 *   getBlock (16 at once)  448 ms   <- concurrency is essentially free
 *   getBlock (32 at once)  813 ms
 * The naive loop (getBlockNumber + getBlock, serially, per block) ran at
 * 1.15 blocks/s against a chain producing 3.3 blocks/s, so it fell behind
 * forever. Fetching a window concurrently and refreshing the head only when
 * we've caught up gives ~35 blocks/s — 10x the chain rate, enough to backfill.
 */
import postgres from 'postgres';
import { readClient, BLOCK_TIME_MS, TokenBucket, withBackoff } from '../../../packages/chain/src/index.ts';
import * as checkpoint from './checkpoint.ts';

const CONSUMER = 'core';
const CONFIRMATIONS = BigInt(process.env.INDEXER_CONFIRMATIONS ?? 2);
/** Blocks fetched per round trip. 16 costs the same as 1; 32 costs ~2x. */
const WINDOW = Number(process.env.INDEXER_WINDOW ?? 16);
/**
 * Sustained RPC calls/sec. The public endpoint killed us at 50/s, so sit well
 * under it and leave room for the gateway and treasury sharing the endpoint.
 * At 1 call per block this is still ~6x the chain's 3.3 blocks/s.
 */
const RPC_RPS = Number(process.env.INDEXER_RPC_RPS ?? 20);
const bucket = new TokenBucket(RPC_RPS, RPC_RPS * 2);

/** Every chain read in this process goes through here. No exceptions. */
async function rpc<T>(label: string, fn: () => Promise<T>): Promise<T> {
  await bucket.take();
  return withBackoff(fn, { label });
}

const sql = postgres(process.env.DATABASE_URL ?? 'postgres://sokoni:sokoni@localhost:5433/sokoni', {
  onnotice: () => {},
});
const chain = readClient();

let running = true;
for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, () => { console.log(`\n${sig} — draining`); running = false; });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main(): Promise<void> {
  let head = await rpc('head', () => chain.getBlockNumber());
  let cp = await checkpoint.load(sql, CONSUMER);

  if (!cp) {
    // Fresh install: start at the head rather than genesis. Backfill is a
    // separate, explicit job — nobody wants an accidental 103M-block replay.
    const start = process.env.INDEXER_START_BLOCK;
    const from = !start || start === 'latest' ? head : BigInt(start);
    const block = await rpc('block', () => chain.getBlock({ blockNumber: from }));
    cp = { blockNumber: block.number, blockHash: block.hash };
    await checkpoint.save(sql, CONSUMER, cp);
    console.log(`indexer: cold start at block ${cp.blockNumber}`);
  } else {
    console.log(`indexer: resuming from block ${cp.blockNumber}`);
  }
  console.log(`indexer: head ${head}, lag ${head - cp.blockNumber}, window ${WINDOW}, ${RPC_RPS} rps cap`);

  let processed = 0n;
  const t0 = Date.now();

  while (running) {
    const target = head - CONFIRMATIONS;

    // Only pay for getBlockNumber (1.1s!) when we think we've caught up.
    if (target <= cp.blockNumber) {
      await sleep(BLOCK_TIME_MS);
      head = await rpc('head', () => chain.getBlockNumber());
      continue;
    }

    const available = Number(target - cp.blockNumber);
    const count = Math.min(WINDOW, available);
    const first = cp.blockNumber + 1n;

    // One round trip for the whole window.
    await bucket.take(count);
    const blocks = await withBackoff(
      () => Promise.all(
        Array.from({ length: count }, (_, i) =>
          chain.getBlock({ blockNumber: first + BigInt(i) })),
      ),
      { label: 'window' },
    );

    // Verify the window is a chain, and that it builds on what we hold.
    let prevHash = cp.blockHash;
    let applied = 0;
    for (const b of blocks) {
      if (b.parentHash !== prevHash) {
        console.warn(`indexer: reorg at ${b.number} — parent ${b.parentHash} != ${prevHash}`);
        break;
      }
      prevHash = b.hash;
      applied++;
    }

    if (applied === 0) {
      cp = await rollback(cp);
      head = await rpc('head', () => chain.getBlockNumber());
      continue;
    }

    const window = blocks.slice(0, applied);
    await processBlocks(window.map((b) => b.number));

    // Checkpoint once per window, not per block: replay is idempotent, so the
    // worst case of a crash mid-window is re-applying up to WINDOW blocks.
    const last = window[applied - 1]!;
    cp = { blockNumber: last.number, blockHash: last.hash };
    await checkpoint.save(sql, CONSUMER, cp);

    processed += BigInt(applied);
    if (processed % 200n < BigInt(applied)) {
      const rate = Number(processed) / ((Date.now() - t0) / 1000);
      console.log(`indexer: at ${cp.blockNumber}, lag ${target - cp.blockNumber}, ${rate.toFixed(1)} blk/s`);
    }
  }

  await sql.end();
  console.log('indexer: stopped cleanly');
}

/**
 * Walk back to a block still on the canonical chain.
 * Projections are pure functions of the log, so rolling back is deleting rows
 * above the common ancestor and replaying — no compensating logic needed.
 */
async function rollback(cp: checkpoint.Checkpoint): Promise<checkpoint.Checkpoint> {
  const n = cp.blockNumber - 1n;
  const candidate = await rpc('block', () => chain.getBlock({ blockNumber: n }));
  await sql.begin(async (tx) => {
    await tx`delete from fills where block_number > ${n.toString()}`;
    await tx`delete from ledger_entries
             where tx_hash is not null
               and tx_hash not in (select tx_hash from fills)`;
  });
  const cp2 = { blockNumber: candidate.number, blockHash: candidate.hash };
  await checkpoint.save(sql, CONSUMER, cp2);
  console.warn(`indexer: rolled back to ${n}`);
  return cp2;
}

/**
 * Decode the events we care about and write projections.
 *
 * Deliberately a no-op until markets are configured: the loop, the
 * checkpointing, the windowing and the reorg handling are the parts that are
 * hard to get right, and they are worth proving on their own. Venue decoding
 * slots in here behind an adapter — one getLogs over the window's block range
 * (not per block), then fills + ledger + candles in one transaction.
 */
async function processBlocks(_blockNumbers: bigint[]): Promise<void> {
  // TODO(venue): chain.getLogs({ address: markets, fromBlock, toBlock }),
  // decode Trade events, insert fills (unique on tx_hash+log_index),
  // then ledger_entries and candles in the same tx.
}

main().catch((err) => {
  console.error('indexer: fatal', err);
  process.exit(1);
});
