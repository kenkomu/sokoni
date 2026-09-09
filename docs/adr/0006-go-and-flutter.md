# 6. Go for the backend, Flutter for the mobile client

Date: 2026-09-09 · Status: accepted · Supersedes the TypeScript scaffold

## Context
The stack was chosen by the project owner: Flutter for mobile, and "Rust or Go"
for the backend. The backend workload is four things: follow the chain, fan out
market data to thousands of WebSocket connections, run pre-trade risk checks on
a latency budget, and keep a ledger that must never be wrong.

## Decision
**Go** for the backend. **Flutter** for mobile.

## Why Go over Rust
- **WebSocket fan-out is the dominant backend workload** and goroutines are
  purpose-built for it. 3,000 concurrent connections is unremarkable in Go.
- **Iteration speed matters more than runtime speed here.** The deadline is 13
  Oct. Go compiles in seconds; the system design shows we are latency-bound by
  a 700 ms biometric prompt and by RPC quota, not by backend CPU. Rust would be
  optimising the term that does not dominate.
- **go-ethereum is the reference EVM implementation**, so ABI encoding, keccak
  and typed data have a mature, widely-audited path.
- Single static binary deploys trivially.

Rust would win if we were writing a matching engine, doing signature
verification in bulk, or needed hard real-time guarantees. ADR 1 says we are
writing none of those — the chain is the matching engine.

**What would change our mind:** if the treasury or risk path grows CPU-bound
crypto work, that component alone can be a Rust service behind the same
interface. The decision is per-service, not per-project.

## Why Flutter is a good fit here
- One codebase for iOS and Android, which is the whole addressable market for a
  mobile trading app, and a single rendering pipeline means the order book and
  candlestick chart look identical on both.
- 60/120fps custom painting suits a live order book better than bridged widgets.
- `passkeys` + `local_auth` reach the platform WebAuthn APIs, which is the whole
  onboarding story (ADR 2).

## Consequences
- The TypeScript scaffold is retired. Its value carried over: the verified
  address set, the ABI notes, the throttle, and the measured RPC numbers all
  moved into `backend/internal/chain`.
- Money is implemented twice — `money.Amount` in Go and `Money` in Dart — with
  the same rule: integer base units plus a scale, never a float, crossing the
  API as a string. **These two must stay in lockstep**; both have tests
  asserting the same behaviours.
- Flutter is not yet installed on the dev machine. `flutter --version` fails;
  install before Phase 2.
