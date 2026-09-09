# 4. Agora is a treasury rail, not a user-facing venue

Date: 2026-09-09 · Status: accepted

## Context
The bounty points at Agora. But Agora Instant Settlement is permissioned: every
swap path is gated on the `APPROVED_SWAPPER` role, and only ~71 addresses hold
it on Monad. Arbitrary user addresses return `false` from `hasRole`. There is
also no Agora deployment on Monad testnet.

Verified live on mainnet: pair `AUSD/USDC` at
`0xf33286E3222D1c829dACeac48c0Ec651F6452470`, `getPrice()` exactly 1e18, both
purchase fees 0, `isPaused()` false, reserves ~9.79M AUSD / ~1.02M USDC.

## Decision
AUSD is the app's unit of account. Users never call Agora. A single whitelisted
treasury address performs AUSD⇄USDC conversion on their behalf, behind a
`SettlementVenue` interface with two adapters: the live Monad pair, and the
Sepolia CTK/AUSD pair for development.

## Consequences
- Works within the whitelist instead of fighting it, and matches the integration
  Agora's own docs describe for "liquidity aggregators and smart contracts".
- Zero slippage at any size becomes a visible product feature, not plumbing.
- Getting the treasury address whitelisted has a human lead time. Agora's CEO and
  CTO are both hackathon mentors — this is a day-one ask, and the Sepolia
  adapter means the demo survives if it does not arrive.
