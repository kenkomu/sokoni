import type { Sql } from 'postgres';

export interface Checkpoint { blockNumber: bigint; blockHash: `0x${string}`; }

/**
 * Checkpoint store.
 *
 * One row per consumer so a new projection can replay from genesis without
 * disturbing the others — the CQRS property from §6 of the system design.
 * We store the block *hash* as well as the number because reorg detection is
 * "does the next block's parentHash match what I last saw", and a number alone
 * cannot answer that.
 */
export async function load(sql: Sql, consumer: string): Promise<Checkpoint | null> {
  const rows = await sql<{ block_number: string; block_hash: Buffer }[]>`
    select block_number, block_hash from indexer_checkpoints where consumer = ${consumer}
  `;
  const row = rows[0];
  if (!row) return null;
  return {
    blockNumber: BigInt(row.block_number),
    blockHash: `0x${row.block_hash.toString('hex')}`,
  };
}

export async function save(sql: Sql, consumer: string, cp: Checkpoint): Promise<void> {
  const hash = Buffer.from(cp.blockHash.slice(2), 'hex');
  await sql`
    insert into indexer_checkpoints (consumer, block_number, block_hash, updated_at)
    values (${consumer}, ${cp.blockNumber.toString()}, ${hash}, now())
    on conflict (consumer) do update
      set block_number = excluded.block_number,
          block_hash   = excluded.block_hash,
          updated_at   = now()
  `;
}
