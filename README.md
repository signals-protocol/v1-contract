# Signals v1 Contracts

Solidity contracts for the Signals v1 protocol.

## Architecture

- **SignalsCore (UUPS)**: central storage and access control
- **Modules**: Trade, MarketLifecycle, Oracle, LPVault, Risk
- **Tokens**: SignalsPosition (ERC-721), SignalsLPShare (ERC-4626)
- **Libraries**: ClmsrMath, RiskMath, FeeWaterfallLib, VaultAccountingLib, LazyMulSegmentTree

## Public Interfaces

- `contracts/interfaces/ISignalsCore.sol` defines the external entrypoints
- Events and custom errors are declared in core contracts and modules

## Build and Test

```bash
yarn install
yarn compile
yarn test
```

## Documentation

- Protocol reference: `v1-docs/docs/reference`
- Whitepaper: `v1-whitepaper/whitepaper.tex`

## Governance and Upgrades

Configuration changes and module wiring are controlled by the governance owner.
