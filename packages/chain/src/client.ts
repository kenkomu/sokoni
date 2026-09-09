import { createPublicClient, defineChain, http, fallback } from 'viem';
import { MONAD_MAINNET, MONAD_TESTNET } from './addresses.ts';

export const monad = defineChain(MONAD_MAINNET);
export const monadTestnet = defineChain(MONAD_TESTNET);

/**
 * Read client.
 *
 * Uses a fallback pool deliberately: §2 of the system design shows the write
 * path alone peaks at ~26 rps against a 25 rps public ceiling, so a single
 * public endpoint is not enough even before market data. Put paid endpoints
 * first in MONAD_RPC_HTTP (comma-separated) as they become available.
 */
export function readClient(urls = process.env.MONAD_RPC_HTTP ?? 'https://rpc.monad.xyz') {
  const list = urls.split(',').map((u) => u.trim()).filter(Boolean);
  return createPublicClient({
    chain: monad,
    transport: fallback(list.map((url) => http(url, { batch: true, retryCount: 2 }))),
  });
}
