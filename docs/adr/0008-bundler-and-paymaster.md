# 8. Our own paymaster, someone else's bundler

Date: 2026-09-10 · Status: accepted · Completes ADR 2

## Context
ADR 2 chose ERC-4337 and noted the consequence: "We need a bundler and a
paymaster. Gas sponsorship is required, not optional." A new user holds no MON,
so without sponsorship they cannot send their first userOp and cannot onboard at
all. Phase 1's gate — a phone with no seed phrase and no MON moving a token —
cannot be met without both.

These are two different things and they do not have to be sourced the same way.
A **bundler** is a service that keeps the alternative mempool, simulates
operations and submits bundles. A **paymaster** is a contract holding a deposit
that agrees to pay.

Monad's own docs list AA providers on mainnet and testnet: Alchemy, Biconomy,
Pimlico, Sequence, thirdweb and ZeroDev, plus FastLane, Gelato and Openfort on
testnet. Every one of them offers a bundler *and* a hosted paymaster.

## Decision
**Use a hosted bundler. Deploy our own paymaster.**

The bundler is reached through the standard ERC-4337 JSON-RPC methods, so the
provider is a URL in configuration and nothing in the code names one.

`SokoniPaymaster` is a verifying paymaster: the backend signs an approval, the
contract checks it. It differs from eth-infinitism's sample in three ways.

1. **The approval commits to an explicit `maxCost`.** The signed gas fields
   already bound the cost arithmetically, but only as well as our own
   multiplication. Checking the EntryPoint's `requiredPreFund` against a
   separately committed ceiling turns an estimation bug into one rejected
   operation instead of a drained deposit.
2. **The signer is rotatable.** A paymaster holds a deposit and a stake; if the
   key leaks, the remedy must not be "deploy a new one, move the deposit, wait
   out the unstake delay, update every client".
3. **`paymasterAndData` is packed, not `abi.encode`d.** The sample spends 64
   bytes carrying 12 bytes of timestamps. Packing saves 52 bytes of calldata per
   operation, which matters here specifically because Monad charges gas on the
   limit rather than the amount used.

## Why not a hosted paymaster
- **Policy is the product.** Who gets sponsored, how much per day, which calls
  qualify — that is a business rule that wants Postgres and Redis and wants to
  change without a redeploy. A hosted paymaster puts it in someone's dashboard.
- **Hosted paymasters generally require that vendor's bundler.** Taking one ties
  both choices together; keeping ours separate means either can be swapped.
- **It is provable locally.** `SokoniPaymaster.t.sol` runs 16 tests under Monad
  execution rules with no fork and no RPC, including an account with a zero
  balance completing a passkey-signed operation.
- Gas sponsorship is the visible half of "no seed phrase, no gas token". Owning
  the contract means the demo shows our code, not a vendor's.

The cost is real: we hold a deposit, we must monitor it, and the paymaster must
be staked. **Staking is not optional** — the contract reads its own storage
during validation to look up the rotatable signer, and ERC-7562 only permits
that for a staked paymaster. An unstaked one is rejected with `-32505`, an error
that does not mention staking.

## The hash that must not drift
The backend builds every userOp and hands the phone a `userOpHash` to sign. Two
implementations of that hash now exist — the EntryPoint's and ours in Go — and
if they disagree by one byte the passkey signs something the account will never
accept. The symptom is a bare `AA24 signature error` from a bundler, with
nothing pointing at the encoding.

So it gets the same treatment as the WebAuthn assertion (ADR 7):
`script/GenUserOpVector.s.sol` emits a golden vector holding both the
`userOpHash` and the paymaster approval digest, Go asserts it reproduces them,
and CI regenerates and diffs. Two implementations checked against each other,
not each against itself.

One trap found while building it: the fixture's `maxCost` is 5×10¹⁷, past the
range a float64 represents exactly. Decoding the vector through `float64` — the
default for a JSON number — rounds it silently and produces a hash that is
wrong for no visible reason. The test loader uses `json.Number` throughout, the
same rule as `money.Amount` and for the same reason.

## Consequences
- go-ethereum enters the backend, as ADR 6 anticipated ("ABI encoding, keccak
  and typed data have a mature, widely-audited path"). Phase 2's event decoding
  wants it too.
- A userOp has two shapes and confusing them wastes an afternoon: the **packed**
  form the EntryPoint hashes, and the **unpacked** form bundlers speak, where
  `initCode` splits into `factory`/`factoryData` and `paymasterAndData` into
  four fields. `Hash()` uses the first; `MarshalJSON()` emits the second.
- **The signing key can spend money.** It is bounded rather than trusted: every
  approval names a maxCost and a validity window, and rotation is one
  transaction. It belongs in a secret manager — `NewSponsorWithKey` exists so it
  need never be a string in config.
- We do not call `eth_estimateUserOperationGas` per order. Monad charges on the
  limit, so an estimate buys nothing at runtime and costs a round trip; limits
  are hardcoded for fixed-shape operations, as Monad's own guidance recommends.
  The method is still implemented, for checking those constants offline.
- **Provider: Pimlico**, decided 2026-09-10, with Alchemy as the configured
  fallback. Pimlico is bundler-first rather than SDK-first, which is the shape we
  need given we supply our own account and paymaster, and it documents v0.6/v0.7/
  v0.8 support. Alchemy is the fallback because it also serves Monad chain RPC,
  so consolidating vendors stays available if that ever beats keeping them
  independent. Neither is named in code; the choice is `BUNDLER_RPC_URL`.
- **FastLane was the near miss.** Its shBundler is Monad-native and explicitly
  tuned for Monad's asynchronous execution and fee model, which is exactly the
  behaviour we design around. It is ruled out by the network path below — Monad's
  docs list it testnet-only — and its paymaster is built on shMON, so its bundler
  may assume its own. Worth revisiting if it reaches mainnet.
- **Network path: testnet now, mainnet for the demo.** Phase 1 proves the passkey
  and sponsorship loop on 10143 where gas is free and mistakes are cheap; the
  demo moves to 143, which is the only place Agora exists (ADR 4). This is what
  rules out testnet-only providers: we need one endpoint family on both.
  Two consequences follow. The paymaster is deployed **twice**, at different
  addresses, and an approval signed for one chain is worthless on the other by
  construction, because the digest commits to both the chain id and the paymaster
  address. And on mainnet the deposit is real money, so it needs a balance metric
  with an alert, not a boot check.
- **Still open:** a Pimlico account and an API key. Nothing reaches a chain until
  that exists and `make deploy-paymaster` has run against each network.

## Verify before trusting
One thing the specs promise and no provider's docs confirm: that a bundler will
accept a paymaster we deployed ourselves. ERC-7562 says any sufficiently staked
paymaster should be accepted, subject to reputation — but "should per spec" and
"does in practice" are different questions, and the answer is cheap to get:
`SupportsConfiguredEntryPoint` at boot, then one sponsored operation on testnet.
If a provider refuses third-party paymasters, that is a same-day swap to the
fallback and no code changes.

## Addendum, 14 Sep 2026 — verified live on Monad testnet

Everything above was proven against a local Anvil chain when written. It has
now run for real: Pimlico's testnet bundler, a `SokoniPaymaster` deployed at
`0xD3918f47F421aA0EC28b1f2d35Bc21F0Ca583287` on chain 10143, and one sponsored
operation that deployed a fresh `SokoniAccount` and landed successfully —
[`0xd3971d64e761b158a8eca6e52833bdd943a1566f9e4406983fb8524c7cddcfbd`](https://testnet.monadexplorer.com/tx/0xd3971d64e761b158a8eca6e52833bdd943a1566f9e4406983fb8524c7cddcfbd).
Confirmed independently on-chain, not just from the harness's own report: the
account carries bytecode, `ownerAt(0)` returns the exact passkey coordinates,
the `UserOperationEvent` log shows `success`, and the paymaster's EntryPoint
deposit dropped by exactly the reported gas cost. The account never held MON.

**Pimlico does accept a third-party paymaster.** The open risk ADR 8 flagged —
"no provider's docs confirm a bundler accepts a paymaster we deployed
ourselves" — is answered: it does, with no special registration step beyond
the stake ERC-7562 already requires.

**Two hardcoded gas defaults were wrong, found only by a live rejection:**

- `preVerificationGas` at `200_000` was ~5.5x too low. Pimlico required
  `1,113,093` for a deploying account whose calldata carries a full WebAuthn
  signature (576 bytes) — bundler overhead and calldata cost that a fixed
  guess had underestimated by a wide margin. Local guesses (from Anvil, or
  from first principles) had no way to catch this; only a real bundler
  simulating a real operation surfaces it.
- `maxFeePerGas` at `100 gwei` was below Pimlico's live floor of `152.5 gwei`.
  Unlike the constant above, this one is market data and will drift again —
  it needed `pimlico_getUserOperationGasPrice` to find the current number, not
  a fixed replacement.

Both `cmd/onboard` and `gateway.DefaultGas()` now carry the measured values
with headroom, and the constants' comments point back to this paragraph so
the next person who has to raise them again knows why they're here and that
they will need raising again.

**`internal/bundler`'s `-32500` hint was too narrow**, and this is what
caught it: the preVerificationGas rejection above came back as `-32500`, the
same code the hint described as "bad signature, or the nonce is already
used". `-32500` is the bundler's general validation-failure bucket; the
attached message says which. The hint was widened to say so rather than
naming one cause the whole bucket doesn't share.
