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

## Test harness coverage (Phase 3-0)
- `test/unit/clmsrParity.test.ts`
  - Closed-form sanity (uniform bins, qty=1, cost/proceeds ≈ α ln(Σ_after/Σ_before)).
  - Round-trip qty→cost→qty on uniform/non-uniform distributions.
  - e2e apply/restore factors (buy then sell) with root sum restored.
  - v0 parity for `_safeExp` via `signals-v0` artifacts (`CLMSRMathHarness`).
- TODO (next add-ons to fully lock plan.md exit criteria):
  - SDK/v0 fixture-based parity for `calculateOpenCost/QuantityFromCost/DecreaseProceeds/CloseProceeds`.
  - Trade-level E2E (`open→increase→decrease→close`, fee on/off) with debit/credit sums checked.
