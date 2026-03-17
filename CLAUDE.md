# v1-contract

Solidity smart contracts (Hardhat + Foundry, yarn).

## Hard Exclusion
**Never access or modify `signals-v0/`** — legacy v0 contracts, excluded from all work.

## Build & Test
```bash
yarn install --frozen-lockfile
yarn hardhat compile
npx hardhat typechain        # ABI/type generation
yarn lint                    # tsc --noEmit strict check
yarn test                    # Hardhat tests
```

## Key Paths
- `contracts/` — main v1 contracts
- `contracts/interfaces/` — contract interfaces (changes → SDK ABI regen)
- `contracts/lib/` — math libraries (changes → SDK quote sync)
- `scripts/dispatcher.ts` — Hardhat deploy/upgrade entrypoint (Category B scripts)
- `script/` — Forge script entrypoints (Category A scripts)
- `script/base/` — BaseScript.s.sol, Constants.s.sol (shared infrastructure)
- `script/config/` — JSON config files for forge scripts
- `script-output/` — Forge script output JSONs (gitignored)
- `scripts/_archived/` — Archived one-off/legacy scripts (Category C)
- `releases/` — deployment manifests (dev/prod JSON plans from prepare-safe-upgrade)

## Cross-Repo Impact
- Event signature change → v1-subgraph schema + mappings
- Interface change → v1-sdk ABI regen (`npx hardhat typechain`)
- Math/rounding change → v1-sdk quote logic sync

## Deploy Scripts

### Forge Scripts (preferred)
- `yarn forge:deploy:dev` — full V1 deployment via forge
- `yarn forge:deploy-fee-policies:dev` — deploy fee policy contracts
- `yarn forge:deploy-impls:dev` — deploy implementation contracts
- `yarn forge:safety-check:dev` / `yarn forge:safety-check:prod` — on-chain verification
- `yarn forge:create-market:dev` — create market (requires config at `script/config/market-dev.json`)
- `yarn forge:close-market:dev` — close/settle market
- `yarn post-deploy <env> <action>` — merge forge output into env JSON

### Hardhat Scripts (Category B — Safe/Redstone dependent)
- `yarn deploy:dev` / `yarn deploy:prod` — contract deployment (Hardhat)
- `yarn upgrade:dev` / `yarn upgrade:prod` — proxy upgrade
- `yarn prepare-safe-upgrade:dev` — generate Safe TX calldata for upgrade

## Style
- OpenZeppelin conventions, NatSpec comments required
- All new functions need happy path + edge case tests
- Bug fixes require regression test

## Git Flow
- Base branch: `main`
