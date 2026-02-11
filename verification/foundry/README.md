# Foundry Numeric Kernel Verification

This directory isolates numeric-kernel verification from the full protocol build.

## What is covered
- `LazyMulSegmentTree` stateful fuzz (`test/LazyMulTreeInvariant.t.sol`)
- Echidna properties on the same target (`src/EchidnaLazyMulTree.sol`)

## Run
```bash
cd verification/foundry
forge test -vv
```

## Echidna (optional)
```bash
cd verification/foundry
echidna . --contract EchidnaLazyMulTree --config echidna.yaml
```

The acceptance threshold for drift is aligned with `/docs/numeric-security-spec.md`.
