## What changed

<!-- One or two sentences. What a reviewer needs to know before reading the diff. -->

## Why

<!-- Link the phase in the delivery plan, or the ADR this implements. -->

## Checklist

- [ ] Anything touching **money, balances or ids** has a test
- [ ] A decision that closes a door has an **ADR** in `docs/adr/`
- [ ] No address typed by hand — it lives in `internal/chain`, verified on-chain
- [ ] `money.Amount` (Go) and `Money` (Dart) still agree, if either changed
- [ ] No secrets, keys or mnemonics in the diff
