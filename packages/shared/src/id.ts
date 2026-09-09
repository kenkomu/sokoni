/**
 * Snowflake IDs — 64-bit, time-sortable, generated without coordination.
 *
 * Layout: 41 bits ms since epoch | 10 bits node | 12 bits sequence.
 * Gives ~4.1M ids/sec/node and sorts by creation time, which is what makes
 * keyset pagination over orders cheap.
 *
 * This is our *handle* for an order, not its settlement identity. The chain's
 * (tx_hash, log_index) is authoritative once the order lands, and the client's
 * Idempotency-Key guards the retry. Three identities, three jobs — see §4 of
 * the system design.
 */
const EPOCH = 1_735_689_600_000n; // 2025-01-01T00:00:00Z
const NODE_BITS = 10n;
const SEQ_BITS = 12n;
const MAX_SEQ = (1n << SEQ_BITS) - 1n;

export class Snowflake {
  #node: bigint;
  #lastMs = 0n;
  #seq = 0n;

  constructor(nodeId = Number(process.env.NODE_ID ?? 0)) {
    if (nodeId < 0 || nodeId >= 1 << Number(NODE_BITS)) {
      throw new Error(`nodeId must be 0..${(1 << Number(NODE_BITS)) - 1}, got ${nodeId}`);
    }
    this.#node = BigInt(nodeId);
  }

  next(): bigint {
    let now = BigInt(Date.now());
    // Clock moved backwards (NTP step). Refuse to mint rather than risk a
    // duplicate id — the caller should retry, and it resolves in milliseconds.
    if (now < this.#lastMs) throw new Error('clock regression; refusing to mint id');

    if (now === this.#lastMs) {
      this.#seq = (this.#seq + 1n) & MAX_SEQ;
      if (this.#seq === 0n) {
        while (now <= this.#lastMs) now = BigInt(Date.now()); // spin to next ms
      }
    } else {
      this.#seq = 0n;
    }
    this.#lastMs = now;
    return ((now - EPOCH) << (NODE_BITS + SEQ_BITS)) | (this.#node << SEQ_BITS) | this.#seq;
  }

  static timestampOf(id: bigint): Date {
    return new Date(Number((id >> (NODE_BITS + SEQ_BITS)) + EPOCH));
  }
}
