# Signals v1 Test Architecture

## Directory Structure

```
test/
├── unit/                   # Pure functions/libraries (no external dependencies)
│   ├── lib/               # Math & data structure libraries
│   │   ├── exposureDiffLib.spec.ts      # Diff array exposure tracking
│   │   ├── feeWaterfallLib.spec.ts      # Fee waterfall algorithm
│   │   ├── fixedPointMath.spec.ts       # WAD arithmetic: wMul, wDiv, wExp, wLn
│   │   ├── fixedPointMathPrecision.spec.ts # High-precision ln/exp tests
│   │   ├── lazyMulSegmentTree.spec.ts   # Segment tree operations
│   │   ├── riskMathLib.spec.ts          # Risk calculations
│   │   ├── signalsDistributionMath.spec.ts # CLMSR distribution math
│   │   ├── tickBinLib.spec.ts           # Tick-bin conversion
│   │   └── vaultAccountingLib.spec.ts   # NAV, shares, price calculations
│   ├── position/          # SignalsPosition contract
│   │   ├── access.spec.ts         # Access control
│   │   ├── erc721.spec.ts         # ERC721 compliance
│   │   ├── signalsPosition.spec.ts # Core position logic
│   │   └── storage.spec.ts        # Storage layout
│   ├── tokens/            # Token contracts
│   │   └── signalsLPShare.spec.ts # LP share token
│   └── tokens/            # Token contracts
│       └── signalsLPShare.spec.ts # LP share token
│
├── module/                 # Individual module tests (delegatecall environment)
│   ├── core/
│   │   └── upgrade.spec.ts     # UUPS upgrade security, onlyDelegated
│   ├── lifecycle/
│   │   └── market.spec.ts      # Market creation, activation, settlement
│   ├── oracle/
│   │   └── oracle.spec.ts      # Oracle signing, settlement value
│   ├── risk/
│   │   └── riskModule.spec.ts  # Risk module logic
│   ├── trade/
│   │   ├── slippage.spec.ts    # Slippage protection
│   │   └── validation.spec.ts  # Input validation (ticks, quantity, time)
│   └── vault/
│       └── lpVaultModule.spec.ts # LP vault module
│
├── integration/            # Multiple modules combined
│   ├── core/
│   │   ├── boundaries.spec.ts     # Edge cases: quantity, ticks, time, cost
│   │   ├── events.spec.ts         # Event emission verification
│   │   ├── riskGateCallOrder.spec.ts # Risk gate call ordering
│   │   └── viewGetters.spec.ts    # View function tests
│   ├── lifecycle/
│   │   └── flow.spec.ts       # Create → trade → settle → claim
│   ├── risk/
│   │   └── alphaEnforcement.spec.ts # α safety bound enforcement
│   ├── settlement/
│   │   ├── chunks.spec.ts         # Chunked settlement processing
│   │   └── payoutReserve.spec.ts  # Payout reserve management
│   ├── trade/
│   │   ├── flow.spec.ts       # Basic open/increase/decrease/close flow
│   │   ├── fuzz.spec.ts       # Property-based random inputs
│   │   └── stress.spec.ts     # High volume, many users
│   └── vault/
│       ├── batchAccounting.spec.ts # Batch accounting logic
│       ├── scenarios.spec.ts       # Vault scenarios
│       ├── unitSystem.spec.ts      # Unit system tests
│       └── vaultBatchFlow.spec.ts  # Daily batch processing
│
├── parity/                 # v0 SDK parity tests
│   ├── clmsr.spec.ts          # Math parity: exp, ln, cost calculations
│   └── tradeModule.spec.ts    # Trading flow parity
│
├── invariant/              # Mathematical invariants
│   ├── clmsr.invariants.spec.ts     # Sum monotonicity, range isolation, symmetry
│   ├── position.invariants.spec.ts  # Position invariants
│   └── rounding.invariants.spec.ts  # Rounding invariants
│
├── security/               # Security-focused tests
│   ├── batch.security.spec.ts       # Batch processing security
│   ├── core.security.spec.ts        # Core contract security
│   ├── escrow.security.spec.ts      # Escrow security
│   ├── market.security.spec.ts      # Market security
│   ├── vault-escrow.security.spec.ts # Vault escrow security
│   └── vault.security.spec.ts       # Vault security
│
├── e2e/                    # Full system tests
│   └── vault/
│       └── vaultWithMarkets.spec.ts # Complete lifecycle with P&L flow
│
└── helpers/                # Shared utilities
    ├── constants.ts       # WAD, USDC_DECIMALS, tolerances
    ├── deploy.ts          # Fixture deployment helpers
    ├── feeWaterfallReference.ts # Fee waterfall reference implementation
    ├── index.ts           # Consolidated exports
    ├── redstone.ts        # Redstone oracle helpers
    └── utils.ts           # approx(), toBN(), createPrng()
```

## Test Layers

### Layer 1: `unit/`

- **What**: Pure functions, libraries, isolated contracts
- **How**: No inter-contract calls, mock dependencies if needed
- **When**: Testing math, data structures, simple logic
- **Example**: `wMul(a, b)` returns correct WAD-scaled product

### Layer 2: `module/`

- **What**: Single module in delegatecall environment
- **How**: TradeModuleProxy or SignalsCore with one module wired
- **When**: Testing module-specific logic, validation, access control
- **Example**: `openPosition()` reverts on invalid tick range

### Layer 3: `integration/`

- **What**: Multiple modules working together
- **How**: Full SignalsCore with all modules, but controlled scenarios
- **When**: Testing flows, state transitions, module interactions
- **Example**: Open position → Settlement → Claim proceeds

### Layer 4: `parity/`

- **What**: v0 SDK vs v1 on-chain implementation
- **How**: Call SDK, call contract, compare results
- **When**: Ensuring backward compatibility and math correctness
- **Example**: SDK.calculateOpenCost() ≈ contract.calculateOpenCost()

### Layer 5: `invariant/`

- **What**: Properties that must always hold
- **How**: Random operations, check invariants after each
- **When**: Finding edge cases, ensuring protocol safety
- **Example**: Sum monotonicity: buy always increases total sum

### Layer 6: `security/`

- **What**: Security-focused edge cases and attack vectors
- **How**: Targeted exploit attempts, access control verification
- **When**: Ensuring protocol cannot be exploited
- **Example**: Reentrancy attacks, unauthorized access attempts

### Layer 7: `e2e/`

- **What**: Complete user journeys
- **How**: Full system deployment, realistic scenarios
- **When**: Final validation before release
- **Example**: LP deposits → Markets trade → Settlement → LP withdraws with profit

## Naming Conventions

| Pattern                      | Meaning                                           |
| ---------------------------- | ------------------------------------------------- |
| `*.spec.ts`                  | All test files (camelCase)                        |
| `{module}.spec.ts`           | Module-specific tests                             |
| `{feature}.{aspect}.spec.ts` | Feature + aspect (e.g., `batch.security.spec.ts`) |
| `flow.spec.ts`               | Standard flow tests                               |
| `boundaries.spec.ts`         | Edge case tests                                   |
| `*.invariants.spec.ts`       | Invariant tests                                   |
| `*.security.spec.ts`         | Security tests                                    |

## Using Helpers

```typescript
// Import from centralized helpers
import { WAD, USDC_DECIMALS, SMALL_QUANTITY } from "../helpers/constants";
import { approx, toBN, createPrng } from "../helpers/utils";
import { deployTradeModuleProxy } from "../helpers/deploy";

// Or use the consolidated index
import { WAD, approx, deployTradeModuleProxy } from "../helpers";
```

## Writing New Tests

1. **Determine the layer**: Is this a pure function? Module? Integration? Security?
2. **Pick the directory**: `unit/`, `module/`, `integration/`, `security/`, etc.
3. **Follow naming**: `{feature}.spec.ts` or `{feature}.{aspect}.spec.ts` (camelCase)
4. **Use helpers**: Don't duplicate constants or utilities
5. **Document invariants**: Reference `docs/vault-invariants.md` if applicable

## Running Tests

```bash
# All tests
yarn test

# Specific layer
yarn hardhat test test/unit/**/*.spec.ts
yarn hardhat test test/integration/**/*.spec.ts

# Specific file
yarn hardhat test test/unit/lib/fixedPointMath.spec.ts
```

## Current Coverage

| Layer        | Files  | Tests    |
| ------------ | ------ | -------- |
| unit/        | 12     | ~120     |
| module/      | 7      | ~40      |
| integration/ | 14     | ~150     |
| parity/      | 2      | ~30      |
| invariant/   | 3      | ~20      |
| security/    | 6      | ~50      |
| e2e/         | 1      | ~34      |
| **Total**    | **45** | **~450** |
