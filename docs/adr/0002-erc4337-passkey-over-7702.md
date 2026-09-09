# 2. ERC-4337 smart accounts with a P256 validator, not EIP-7702

Date: 2026-09-09 · Status: accepted

## Context
We need accounts a phone can control with Face ID and no seed phrase. Two routes
exist on Monad: delegate an EOA via EIP-7702, or deploy an ERC-4337 smart account
with a WebAuthn/P256 validator.

Verified on mainnet: EntryPoint v0.7 is deployed at
`0x0000000071727De22E5E9d8BAf0edAc6f37da032`, and the secp256r1 precompile
(EIP-7951) is at `0x0100`, so a Secure Enclave signature verifies on-chain.

## Decision
ERC-4337 with a P256 validator module.

## Consequences
- Rejected 7702 because Monad reverts any transaction that would drop a
  *delegated* EOA below **10 MON**, and delegated code cannot call CREATE/CREATE2.
  Requiring every new user to pre-fund 10 MON kills onboarding.
- We need a bundler and a paymaster. Gas sponsorship is required, not optional.
- Multi-device and recovery come free: the account holds several registered
  passkeys, and adding one is authorised by an existing one plus a timelock.
- Session keys become possible (ADR 5), which is where the latency win is.
