# CLMSR invariants & SDK parity checklist (Phase 3-0)

This note captures the behavior we must lock before touching structure or math.
Use it to write/extend tests in `test/unit/clmsrParity.test.ts` (parity + round-trip).

## Scope
- Functions: `_calculateTradeCostInternal`, `_calculateQuantityFromCostInternal`, `_calculateSellProceeds`, `_safeExp`, `_computeSafeChunk`.
- Entry points: `calculateOpenCost`, `calculateIncreaseCost`, `calculateDecreaseProceeds`, `calculateCloseProceeds`, `calculatePositionValue`.
- Domain objects: `Market` ticks/bins, `LazyMulSegmentTree` sums.

## Invariants (must hold pre/post refactor)
- **Positivity / domain**
  - `liquidityParameter > 0`.
  - `sumBefore > 0`, `sumAfter > 0`.
  - `_safeExp` input bounded by `MAX_EXP_INPUT_WAD`, otherwise revert.
  - `_computeSafeChunk` always returns `chunkQty > 0` and `chunksLeft` decreases.
- **Monotonicity**
  - `cost` increases with larger `quantity` for buys.
  - `proceeds` increases with larger `quantity` for sells.
  - `quantityFromCost` is monotone with respect to `cost`.
- **Rounding**
  - User debits (cost) use **ceil** toward payer.
  - User credits (proceeds) use **floor** toward protocol.
  - Round-trip: `qty -> cost -> qty'` within 1 ulp of quantity discretization.
- **Tick semantics**
  - `lowerTick < upperTick`, `(upperTick - lowerTick) % tickSpacing == 0`.
  - `minTick <= lowerTick`, `upperTick <= maxTick`.
  - Settlement tick uses `[lowerTick, upperTick)` half-open interval.
- **Revert cases**
  - Invalid tick range, zero quantity, overflow in exp/chunk → revert (no silent wrap).
  - Settlement before `startTimestamp` or after `endTimestamp` rejected.

## SDK parity targets
- For random `(alpha, distribution, lowerTick, upperTick, quantity)`:
  - `calculateOpenCost` (on-chain) ≈ SDK `calculateOpenCost`.
  - `calculateQuantityFromCost` (derived from SDK) matches within tolerance.
  - `calculateDecreaseProceeds`, `calculateCloseProceeds` parity.
- Round-trip property tests:
  - `qty -> cost -> qty'` within rounding tolerance.
  - `proceeds -> qty -> proceeds'` within rounding tolerance.

## Settlement snapshot assumptions (for later phases)
- `openPositionCount` is the count of positions with `quantity > 0` at settlement.
- Snapshot batching uses `SettlementChunkRequested(marketId, chunkIndex)` with `CHUNK_SIZE`.
- Subgraph assigns `seqInMarket` off-chain; on-chain does **not** emit per-position events.

## Test harness plan (to implement in Phase 3-0)
- `test/unit/clmsrParity.test.ts`
  - SDK parity cases (pull fixtures from v0 or SDK once wired). Drop JSON fixtures in `test/fixtures/clmsrFixtures.json` (shape in `clmsrFixtures.sample.json`).
  - Round-trip property tests (fuzzable).
  - E2E scenario: `open → increase → decrease → close` with/without fee, assert debit/credit sums.
- Harness auto-skips if `clmsrFixtures.json` is absent, so CI stays green until fixtures are added.
