# Signals v1

On-chain prediction market protocol built on CLMSR (Continuous Logarithmic Market Scoring Rule).

## Overview

Signals is a modular smart contract system for prediction markets. It features:

- **CLMSR-based pricing** — Logarithmic market scoring with O(log n) range queries
- **Position NFTs** — ERC721 tokens representing market positions
- **LP Vault** — ERC-4626 compatible liquidity pool with async batch processing
- **Risk module** — α safety bounds, exposure caps, prior admissibility checks
- **Upgradeable architecture** — UUPS proxy pattern with delegate modules

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      SignalsCore (UUPS)                     │
│  - Central storage holder                                   │
│  - Module routing via delegatecall                          │
│  - Access control (Ownable, Pausable, ReentrancyGuard)      │
└─────────────────────────────────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
   ┌───────────┐       ┌───────────┐       ┌───────────┐
   │  Trade    │       │ Lifecycle │       │  Oracle   │
   │  Module   │       │  Module   │       │  Module   │
   └───────────┘       └───────────┘       └───────────┘
         │                    │                    │
         └────────────────────┼────────────────────┘
                              ▼
                    ┌─────────────────┐
                    │ SignalsPosition │
                    │    (ERC721)     │
                    └─────────────────┘
```

## Project Structure

```
contracts/
├── lib/                            # All libraries (no nested lib folders)
│   ├── FixedPointMathU.sol         # WAD arithmetic
│   ├── LazyMulSegmentTree.sol      # CLMSR segment tree
│   ├── ClmsrMath.sol               # CLMSR cost/proceeds calculation
│   ├── RiskMath.sol                # α/drawdown/ΔE calculations
│   ├── FeeWaterfallLib.sol         # Fee distribution
│   ├── VaultAccountingLib.sol      # Vault NAV/batch accounting
│   ├── ExposureDiffLib.sol         # Exposure delta tracking
│   └── TickBinLib.sol              # Tick/bin conversion
├── core/
│   ├── SignalsCore.sol             # UUPS entry point
│   └── SignalsCoreStorage.sol      # Canonical storage layout
├── modules/                        # Delegate modules (no nested folders)
│   ├── TradeModule.sol             # Open/close/claim positions
│   ├── MarketLifecycleModule.sol   # Create/settle markets
│   ├── OracleModule.sol            # Settlement price feed
│   ├── LPVaultModule.sol           # LP deposit/withdraw
│   └── RiskModule.sol              # α bounds, exposure caps
├── position/
│   └── SignalsPosition.sol         # Position NFT (ERC721)
├── tokens/
│   └── SignalsLPShare.sol          # LP share token (ERC-4626)
├── interfaces/                     # Contract interfaces
├── errors/                         # Custom errors
└── testonly/                       # Test harnesses and mocks

test/
├── unit/lib/     # Library unit tests
├── module/       # Single module tests
├── integration/  # Cross-module flows
├── invariant/    # Math property tests
├── parity/       # SDK compatibility
├── security/     # Access control
└── e2e/          # End-to-end scenarios
```

## Getting Started

```bash
# Install dependencies
yarn install

# Compile
yarn compile

# Test
yarn test

# Test specific file
yarn test test/unit/FeeWaterfallLib.spec.ts
```

## Operations

See `OPERATIONS.md` for deployment, upgrades, and release runbooks.

## Core Concepts

### Markets

Markets are prediction markets with:

- Tick range `[tickLower, tickUpper)`
- Start/end timestamps
- Settlement price from oracle

### Positions

Positions are ERC721 tokens representing:

- Market ID
- Tick range
- Quantity

### LP Vault

Liquidity providers deposit collateral and receive shares. The vault:

- Processes deposits/withdrawals in daily batches
- Calculates NAV, price, and drawdown
- Distributes fees via waterfall

## Key Formulas

```
// CLMSR cost function
C(q) = α · ln(Z_after / Z_before)

// Vault batch price
P_t = N_t / S_t

// α safety bound
α_base = λ · E_t / ln(n)
α_limit = α_base · (1 - k · DD_t)

// Fee waterfall
F_loss = min(F_tot, |L_t|)
N_pre = N_{t-1} + L_t + F_t + G_t
```

## Testing

```bash
# Run all tests
yarn test

# Run with coverage
yarn coverage

# Run specific suite
yarn test --grep "FeeWaterfallLib"
```

**530+ tests** covering:

- SDK parity within ≤1 wei
- Math invariants (100+ fuzz cases)
- Edge cases and boundary conditions
- Access control and security

## License

MIT
