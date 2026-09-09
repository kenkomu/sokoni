/**
 * Monad mainnet addresses.
 *
 * Every address here was read back from https://rpc.monad.xyz on 2026-09-09
 * (block 103,290,450) and confirmed to have bytecode. Do not add an address to
 * this file that has not been verified on-chain — a typo'd address is a silent
 * fund loss, not a crash.
 */

export const MONAD_MAINNET = {
  id: 143,
  name: 'Monad',
  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.monad.xyz'], webSocket: ['wss://rpc.monad.xyz'] } },
  blockExplorers: { default: { name: 'MonadVision', url: 'https://monadvision.com' } },
} as const;

export const MONAD_TESTNET = {
  id: 10143,
  name: 'Monad Testnet',
  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: ['https://testnet-rpc.monad.xyz'], webSocket: ['wss://testnet-rpc.monad.xyz'] } },
  blockExplorers: { default: { name: 'MonadVision', url: 'https://testnet.monadvision.com' } },
} as const;

/** Average block time measured over 1,000 mainnet blocks on 2026-09-09. */
export const BLOCK_TIME_MS = 300;

export const TOKENS = {
  AUSD: { address: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a', decimals: 6, symbol: 'AUSD' },
  USDC: { address: '0x754704Bc059F8C67012fEd69BC8A327a5aafb603', decimals: 6, symbol: 'USDC' },
  WMON: { address: '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A', decimals: 18, symbol: 'WMON' },
} as const;

/**
 * Agora Instant Settlement. Fixed-price, non-AMM. Verified live: getPrice() is
 * exactly 1e18, both purchase fees are 0, isPaused() is false.
 *
 * ACCESS IS GATED. Calling any swap path requires the APPROVED_SWAPPER role on
 * the pair; ~71 addresses hold it. See docs/adr/0004-agora-as-treasury-rail.md.
 */
export const AGORA = {
  factory: '0x8468587Af422ad440F58a57E955eCA6A970b5375',
  pairs: {
    'AUSD/USDC': '0xf33286E3222D1c829dACeac48c0Ec651F6452470',
  },
  whitelisterRole: 'WHITELISTER_ROLE',
  swapperRole: 'APPROVED_SWAPPER',
} as const;

/** ERC-4337. Both EntryPoint versions are canonical on Monad and verified deployed. */
export const ERC4337 = {
  entryPointV07: '0x0000000071727De22E5E9d8BAf0edAc6f37da032',
  entryPointV06: '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789',
} as const;

/** secp256r1 verification (EIP-7951). This is what makes passkey accounts possible. */
export const P256_PRECOMPILE = '0x0000000000000000000000000000000000000100' as const;
