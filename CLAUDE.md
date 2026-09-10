# Sokoni — working notes

A passkey-native, AUSD-denominated mobile trading app on Monad. Three toolchains
in one repo: Go backend, Flutter client, Foundry contracts.

`README.md` says what the project is and what was measured. `docs/adr/` says why
things are the way they are — read the ADR before reopening a decision. This file
is the operational layer: the things that will bite you, and the invariants that
must not be broken casually.

## Commands

`make help` lists everything. `make ci` is meant to run exactly what CI runs.

```
make up        # postgres :5433, redis :6380
make migrate   # apply backend/migrations/0001_init.sql
make go-check  # gofmt gate + vet + race tests
make dart-check
make sol-check
make ci        # all three
```

## Toolchain floors, and why they are floors

- **Foundry ≥ 1.8.0.** Monad execution support landed there. On anything older
  the P-256 precompile at `0x0100` is simply absent and the failure is maximally
  misleading: the staticcall *succeeds* returning empty, which is
  indistinguishable from an invalid signature. CI fails loudly on < 1.8.
- **Dart SDK ≥ 3.7** in `pubspec.yaml`. The formatter only switches to tall
  style at 3.7+. A lower constraint makes local and CI formatters disagree about
  the same file, and no single file can satisfy both.
- **Flutter 3.47.2** at `~/develop/flutter` (bin on PATH). Matches CI exactly, so
  analyzer and formatter agree.
- **Go 1.26**, per `backend/go.mod`.

## CI gotchas already solved — do not reintroduce

- **Run the gitleaks binary, not `gitleaks-action`.** The action derives a commit
  range from the push event, which is unresolvable on a first push
  (`<first-commit>^` does not exist) and after a force-push. Scanning full
  history is deterministic on every event.
- **Secrets are allowlisted in `.gitleaks.toml`, never `.gitleaksignore`.**
  Fingerprints embed a commit hash and go stale every time the WebAuthn fixture
  is regenerated. The config extends the default ruleset and carves out only the
  fixture paths and `contracts/lib/`.
- **Contract tests need no fork and no RPC.** `network = "monad"` in
  `foundry.toml` gives Monad's precompiles, gas model and 128 KB size limit
  locally. Forking does *not* help — a fork copies state, not execution rules.
  `make sol-check` used to pass `--fork-url` where CI did not; the flag is gone,
  so the two now match. Do not add it back.
- **Postgres 18's image wants its volume at `/var/lib/postgresql`**, not `/data`.
- **`mobile` CI formats in place then diffs**, so a failure shows exactly what to
  change rather than only naming the file.

## The invariants

**One indexer.** It holds the only chain read subscription in the platform. If
every client polled we would need ~3,000 rps against a 50 rps ceiling; one
follower keeps chain load flat at the block rate regardless of user count. This
is the decision the architecture turns on (ADR 1, ADR 5). Everything else reads
Postgres or Redis. Do not add a second chain reader without reopening ADR 5.

**The chain is the sequencer.** `(block, txIndex, logIndex)` is already a total
order agreed by consensus, so we build the ring around a matching core and never
the core itself. All read state is a projection of chain events and is
rebuildable by replay — recovery is replay, never a compensating transaction.
No TC/C, no Saga, no two-phase commit (ADR 3).

**Money is never a float.** `money.Amount` in Go and `Money` in Dart: integer
base units plus the scale those units are in, crossing the API as a string.
Tokens do not share a scale — AUSD and USDC are 6 decimals, MON and WMON are 18 —
so the scale travels with the value. **The two implementations must stay in
lockstep**; both have tests asserting the same behaviours.

**An address is never typed twice.** Every address lives in
`backend/internal/chain/addresses.go`, read back from mainnet and EIP-55
checksum-verified. A typo'd address is a silent loss of funds, not a crash.

**Halt on drift.** Reconciliation compares the ledger against on-chain balances
continuously. An unexplained discrepancy stops trading and pages a human — it is
never adjusted to match.

## Client/server split

**The phone does not ABI-encode.** The backend builds the userOp, hands the
client a `userOpHash` to sign, and encodes the result. So the phone needs no
chain libraries, and encoding lives in exactly one place, in Go.

The client's job at the boundary is narrow and specific:

- Parse the platform authenticator's output — COSE_Key on registration, DER
  signature on assertion — and reject anything that is not ES256/P-256.
- **Normalise `s` to the low half of the curve order before submitting.** Monad's
  precompile accepts both `(r, s)` and `(r, N−s)`, so `SokoniAccount` rejects the
  high form; authenticators return either, so without normalisation roughly half
  of all signatures would be rejected. `parseDerSignature` does this at the
  boundary so nothing downstream has to remember.
- Compute the `challengeIndex` and `typeIndex` byte offsets into
  `clientDataJSON`. The contract does not parse JSON; it is told where to look
  and asserts the expected bytes sit there. The signature covers the whole JSON,
  so a wrong offset can only make verification fail, never smuggle content past
  it.

## Passkey account, non-obvious parts

- **A WebAuthn assertion is not a signature over the challenge.** The
  authenticator signs `sha256(authenticatorData || sha256(clientDataJSON))`, and
  the challenge appears only inside the JSON, base64url encoded. Verify the
  reconstructed structure, not a bare signature.
- **Validation returns `SIG_VALIDATION_FAILED`, never reverts.** A revert during
  the ERC-4337 validation phase fails the whole bundle and can get the sender
  banned by bundlers.
- **`handleOps` swallows execution-phase reverts** (emitting
  `UserOperationRevertReason`); only validation failures propagate. So tests
  assert state for the former and can `expectRevert` only for the latter.
- **Precompiles carry no bytecode**, so `extcodesize(0x100)` is 0. Any "is this a
  contract" guard wrongly concludes it is absent.
- **Require user verification, not merely user presence.** This account moves
  money; a tap is not enough.

## Test vectors

`contracts/script/gen_webauthn_vector.py` is a pure-Python P-256 implementation,
so fixtures are reproducible and auditable rather than pasted from an
unverifiable source. The frozen vector was independently confirmed against the
live precompile on mainnet.

**The same fixture is used by the Solidity tests and the Dart tests**, and CI
diffs the two copies. That is what stops the client and the contract from being
self-consistently wrong in a way that would only surface on a real device against
a real chain. `make fixture-sync` copies contracts → mobile after regenerating.

`ffi = true` is on so account tests can sign a `userOpHash` they only learn at
runtime, rather than replaying one fixture.

## ERC-4337 plumbing

**A userOp has two shapes and confusing them wastes an afternoon.** The *packed*
form is what the EntryPoint hashes and the account sees: `verificationGasLimit`
and `callGasLimit` share one word (verification in the high half), the two gas
fees share another, and the paymaster fields are one opaque byte string. The
*unpacked* form is what bundlers speak over JSON-RPC: every field separate,
`initCode` split into `factory`/`factoryData`, `paymasterAndData` split into
four. `userop.Hash()` uses the first; `userop.MarshalJSON()` emits the second.

**Order matters when sponsoring.** `paymasterAndData` must be final before the
userOpHash is taken, because the hash covers it. Sponsor first, then hash, then
hand the hash to the phone. `Sponsor.Approve` deliberately leaves the operation
unmutated so a stub can never be hashed in by accident.

**The paymaster must be staked, not just funded.** The deposit pays for gas; the
stake is what lets it read its own storage during validation (ERC-7562), which
ours does to look up the rotatable signer. An unstaked paymaster is rejected
with `-32505`, an error that does not mention staking.

**One golden vector pins the hashes and every ABI encoding across Solidity and
Go** (`contracts/test/fixtures/userop_vector.json`, generated by
`make userop-vector`): the userOpHash, the paymaster approval digest, and the
encodings of the passkey signature, `execute`, and `createAccount`. Same
discipline as the WebAuthn fixture, same reason — a wrong hash gives you a bare
`AA24 signature error` and a wrong signature encoding gives you `AA23 reverted`,
and neither mentions encoding.

Two traps that fixture has already caught. Decode it with `json.Number`, never a
float: `maxCost` is 5e17, past float64's exact integer range. And `clientDataJSON`
is emitted as **hex bytes**, because `vm.serializeString` detects valid JSON and
inlines it as a nested object.

**`make onboard` drives one sponsored operation against a live chain** and prints
each step. It signs with the Python test passkey rather than a device, so the
whole 4337 path can be proven with no phone and no Digital Asset Links setup —
then the signer is swapped for the real authenticator and only one variable is
new.

## Gateway

The phone's only door onto the chain (`backend/internal/gateway`, ADR 9). Every
operation is two round trips — **prepare** (intent in, challenge out) then
**submit** (assertion in, bundler out). Four rules, each closing a failure:

- **Intents, never calldata.** The phone asks for a transfer; the gateway
  encodes it. An endpoint that sponsored arbitrary calldata would be a free gas
  tap for any contract call anyone could think of.
- **Never rebuild on submit.** The nonce, gas and sponsorship window are inside
  the hash the user signed. The prepared operation is held byte for byte and
  only the signature is attached.
- **Verify the assertion before the bundler sees it.** The contract would reject
  a bad one anyway — but bundlers track paymaster reputation (ERC-7562), and a
  paymaster whose operations keep failing validation is throttled for *every*
  user. `account.VerifyAssertion` mirrors `WebAuthn.sol` check for check.
- **Don't sponsor a transfer that must revert.** Reverted execution still costs
  the paymaster its gas, so prepare checks `balanceOf` first.

The submit body is exactly what `PasskeyAssertion.toJson()` emits, so there is
no mapping layer to drift. Values arrive zero-padded to 32 bytes: decode with
`parseWord`, never `hexutil.DecodeBig`, which rejects leading zeros and would
refuse roughly one key in 256.

## Known gaps

- `store.ApplyBlocks` has a `TODO(venue)`: it advances the checkpoint but decodes
  no logs, so the indexer follows the chain and projects nothing yet. The venue
  (the on-chain CLOB) is not yet named in code.
- Five of fifteen `internal` packages are `.gitkeep` — `auth`, `marketdata`,
  `orders`, `treasury`, `observability` — plus two of five `cmd` entrypoints
  (`reconciler`, `treasury`).
- On mobile, only `features/onboarding` exists; `markets`, `trade`, `portfolio`,
  `settings` and the `domain/` layer are placeholders.
- **Nothing here has ever run against a live chain.** The bundler, paymaster and
  `cmd/onboard` harness are built and tested, but there is no Pimlico API key,
  and neither the factory nor the paymaster is deployed on any network.
- **The phone ↔ gateway loop has only run against fakes.** Both sides are
  tested and the wire format is pinned from each, but no device has talked to
  a running gateway yet.
- The gateway keeps prepared operations **in memory**: correct for one
  instance, wrong for two (prepare on one, submit to another → "no such
  operation"). Redis before a second instance.
- No rate limiting and no per-account sponsorship caps yet. The balance check
  stops the cheapest drain — empty accounts — but a funded account still costs
  the paymaster gas per operation. Phase 3's risk checks close this.
