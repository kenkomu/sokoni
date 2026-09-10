# 9. The gateway: two-step operations, verified before they reach a bundler

Date: 2026-09-10 · Status: accepted · Completes Phase 1 alongside ADR 8

## Context
ADR 8 built the paymaster and the bundler client. Neither is reachable by the
phone: the client/server split (CLAUDE.md) says the phone holds a passkey and
nothing else — no chain libraries, no ABI encoding, no calldata. Something has
to sit between "the user wants to send a token" and "a signed userOp is on a
bundler's mempool".

## Decision
**Every operation is two HTTP round trips.**

- `POST /v1/ops` — the phone states an intent (`{kind, token, to, amount}`).
  The gateway builds the operation, sponsors it via `paymaster.Sponsor`, and
  returns its `userOpHash` as a WebAuthn challenge.
- `POST /v1/ops/{id}/submit` — the phone returns the signed assertion. The
  gateway verifies it, encodes it into the signature field, and sends the
  *exact* operation it built at step one to the bundler.

The operation is held server-side, byte for byte, between the two calls. It is
never rebuilt on submit — the nonce, gas limits and sponsorship window are all
inside the hash the user just signed, and rebuilding any of them would make
that signature worthless. `TestPreparedOperationIsNotRebuiltOnSubmit` asserts
this by moving the world (nonce, deployment state) between prepare and submit
and checking nothing sent downstream changed.

## Why verify the assertion again before the bundler sees it
`SokoniAccount` would reject a bad assertion anyway — this is not the security
boundary. It exists because of what happens *before* the contract gets a say:
bundlers simulate validation, and ERC-7562 tracks paymaster reputation. A
paymaster whose sponsored operations keep failing validation is throttled and
then banned (`-32504`) — for every user, not just the one who sent the bad
signature. `account.VerifyAssertion` mirrors `WebAuthn.sol` check for check
(RP binding, UP/UV flags, type, challenge offset, low-s, the P-256 check
itself) so a malformed or stale assertion costs one `400`, never a strike
against the shared paymaster.

## Why intents, never calldata
The phone asks for `{kind: "transfer", token, to, amount}`. An endpoint that
accepted and sponsored arbitrary calldata would be a general-purpose free gas
tap for any contract call anyone could think of. The intent vocabulary is
Phase 1's whole surface: one kind, `transfer`, against an explicit token
allowlist (`SPONSORED_TOKENS`). Widen it deliberately, not by accident.

## Why prepare checks the balance before sponsoring
A transfer that is certain to revert still costs the paymaster its gas —
reverted execution is paid for (`IPaymaster.PostOpMode.opReverted`). Without a
check, anyone could create empty accounts and drain the deposit one failed
transfer at a time. `Prepare` calls `balanceOf` and refuses with a message
that names the fix: *"not enough TST — deposit or reduce the amount"*, never
*"risk check 4 failed"*.

## Consequences
- **Idempotent submit.** A second submit of an already-sent operation returns
  the first result rather than sending twice — two taps on a flaky connection
  must not become two bundler submissions, the same discipline the order
  service will need in Phase 3.
- **Operations live in memory**, correct for one gateway instance and wrong
  for two: prepare on one, submit to another, and the answer is "no such
  operation". The system design's stateless edge means this becomes Redis
  before there is a second instance; the `PendingOps` interface is the seam.
- **Boot-time preflight, not runtime discovery.** The gateway refuses to start
  if the bundler cannot serve the configured EntryPoint, or if the deployed
  paymaster's registered signer differs from the key the gateway signs with
  (`Sponsor.VerifyDeployment`, from ADR 8). Both failures are otherwise total
  and silent — every operation rejected with an opaque `AA` code — so they are
  far cheaper to catch before the first request than after the hundredth.
- **The submit body is exactly `PasskeyAssertion.toJson()`.** No mapping layer
  between the phone and the gateway to drift out of step; the wire contract is
  pinned from both sides (`http_test.go`, `api_test.dart`).
- **No rate limiting, no per-account sponsorship caps yet.** The balance check
  stops the cheapest drain; a funded account still costs the paymaster gas per
  operation with no ceiling. That is Phase 3's risk-check surface, not this
  one's — recorded here so it isn't mistaken for done.
