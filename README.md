# Signals v1

Modular on-chain architecture for the Signals prediction market protocol, built on CLMSR (Continuous Logarithmic Market Scoring Rule).

## Current Status

**Phase 3 Complete** — v0 parity achieved with modular architecture.

| Component               | Status | Description                                        |
| ----------------------- | ------ | -------------------------------------------------- |
| `SignalsCore`           | ✅     | UUPS upgradeable entry point with delegate routing |
| `TradeModule`           | ✅     | Position open/increase/decrease/close/claim        |
| `MarketLifecycleModule` | ✅     | Market creation, settlement, timing updates        |
| `OracleModule`          | ✅     | Settlement price feed with signature verification  |
| `SignalsPosition`       | ✅     | ERC721 position NFT with market indexing           |
| `LazyMulSegmentTree`    | ✅     | O(log n) range queries for CLMSR distribution      |

**56 tests passing** — SDK parity, fuzz, stress, slippage, settlement chunks, access control.

### Progress

- [x] Phase 0: Repository bootstrap
- [x] Phase 1: Storage / Interface design
- [x] Phase 2: Core + module scaffolding
- [x] Phase 3: v0 logic porting (Trade, Lifecycle, Oracle, Position)
- [ ] Phase 4: Risk module hooks
- [ ] Phase 5: LP Vault / Backstop integration
- [ ] Phase 6: Mainnet preparation

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      SignalsCore (UUPS)                     │
│  - Storage holder (SignalsCoreStorage)                      │
│  - Module routing via delegatecall                          │
│  - Access control (Ownable, Pausable, ReentrancyGuard)      │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐   ┌─────────────────────┐   ┌─────────────┐
│  TradeModule  │   │ MarketLifecycleModule │  │ OracleModule │
│  - openPosition   │  - createMarket       │  │ - submitPrice │
│  - increasePosition│ - settleMarket       │  │ - getSettlement│
│  - decreasePosition│ - requestSettlement  │  └─────────────┘
│  - closePosition  │    Chunks             │
│  - claimPayout    └─────────────────────┘
│  - calculate*     │
└───────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    SignalsPosition (ERC721)                 │
│  - Position NFT with market/owner indexing                  │
│  - Core-only mint/burn/update                               │
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
signals-v1/
├── contracts/
│   ├── core/
│   │   ├── SignalsCore.sol              # UUPS entry point
│   │   ├── storage/SignalsCoreStorage.sol
│   │   └── lib/
│   │       ├── SignalsClmsrMath.sol     # CLMSR math helpers
│   │       └── SignalsDistributionMath.sol
│   ├── modules/
│   │   ├── TradeModule.sol              # Trade execution
│   │   ├── MarketLifecycleModule.sol    # Market management
│   │   └── OracleModule.sol             # Settlement oracle
│   ├── position/
│   │   ├── SignalsPosition.sol          # ERC721 position token
│   │   └── SignalsPositionStorage.sol
│   ├── lib/
│   │   ├── LazyMulSegmentTree.sol       # Segment tree for CLMSR
│   │   └── FixedPointMathU.sol          # 18-decimal fixed point
│   ├── interfaces/
│   ├── errors/
│   ├── mocks/
│   └── harness/                         # Test helpers
├── test/
│   ├── unit/                            # Module-level tests
│   ├── integration/                     # Cross-module flows
│   └── e2e/
├── docs/
│   └── phase3/clmsr-invariants.md
└── plan.md                              # Full migration plan
```

## Getting Started

```bash
# Install dependencies
yarn install

# Compile contracts
yarn compile

# Run tests
yarn test

# Run specific test file
yarn test test/integration/tradeModule.flow.test.ts
```

## Key Design Decisions

1. **Thin Core + Delegate Modules** — Core holds storage and routes to modules via delegatecall. Modules can be upgraded independently.

2. **24KB Size Limit** — Heavy logic in modules, not Core. Trade/Lifecycle can be split further if needed.

3. **Clean Storage Layout** — v1 canonical layout with gaps for future upgrades. No legacy fields from v0.

4. **SDK Parity** — On-chain calculations match v0 SDK within ≤1 μUSDC tolerance.

## Documentation

- [plan.md](./plan.md) — Detailed architecture and migration plan
- [docs/phase3/clmsr-invariants.md](./docs/phase3/clmsr-invariants.md) — CLMSR math invariants

## License

MIT
