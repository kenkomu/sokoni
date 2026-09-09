/**
 * Token bucket over the RPC transport.
 *
 * This is the "global RPC egress" bucket from the system design's rate-limit
 * table — the one protecting the resource that actually costs money and that
 * every service shares.
 *
 * Why it exists, concretely: an unthrottled windowed indexer reached 38.5
 * blocks/s against https://rpc.monad.xyz and was killed by the provider with
 * `-32007  50/second request limit reached`. Note that is 50/s, not the 25 rps
 * the Monad docs quote — do not trust either number, throttle to what you
 * configured and leave headroom for the other services sharing the endpoint.
 *
 * Token bucket rather than fixed window for the same reason as the gateway:
 * it absorbs a burst up to bucket size while capping the sustained rate, and a
 * backfill is exactly a legitimate burst.
 */
export class TokenBucket {
  readonly ratePerSec: number;
  readonly capacity: number;
  #tokens: number;
  #lastRefill: number;

  constructor(ratePerSec: number, capacity: number = ratePerSec * 2) {
    this.ratePerSec = ratePerSec;
    this.capacity = capacity;
    this.#tokens = capacity;
    this.#lastRefill = Date.now();
  }

  async take(n = 1): Promise<void> {
    if (n > this.capacity) throw new Error(`request of ${n} exceeds bucket capacity ${this.capacity}`);
    for (;;) {
      this.#refill();
      if (this.#tokens >= n) { this.#tokens -= n; return; }
      const deficit = n - this.#tokens;
      await new Promise((r) => setTimeout(r, Math.ceil((deficit / this.ratePerSec) * 1000)));
    }
  }

  #refill(): void {
    const now = Date.now();
    const elapsed = (now - this.#lastRefill) / 1000;
    if (elapsed <= 0) return;
    this.#tokens = Math.min(this.capacity, this.#tokens + elapsed * this.ratePerSec);
    this.#lastRefill = now;
  }
}

/** Provider rate-limit signals. Retryable — the request was never served. */
export function isRateLimited(err: unknown): boolean {
  const e = err as { code?: number; status?: number; details?: string; message?: string };
  if (e?.code === -32007 || e?.status === 429) return true;
  const text = `${e?.details ?? ''} ${e?.message ?? ''}`.toLowerCase();
  return text.includes('request limit') || text.includes('rate limit') || text.includes('too many requests');
}

/**
 * Retry with exponential backoff and full jitter.
 *
 * A rate limit must never take the indexer down: a crash-looping follower
 * falls further behind on every restart, which is strictly worse than pausing.
 */
export async function withBackoff<T>(
  fn: () => Promise<T>,
  { tries = 6, baseMs = 250, maxMs = 8_000, label = 'rpc' } = {},
): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < tries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (!isRateLimited(err) && attempt >= 2) throw err;
      const backoff = Math.min(maxMs, baseMs * 2 ** attempt);
      const wait = Math.random() * backoff; // full jitter: avoids retry convoys
      console.warn(`${label}: attempt ${attempt + 1}/${tries} failed, retrying in ${Math.round(wait)}ms`);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw lastErr;
}
