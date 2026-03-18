# v1-contract

Solidity smart contracts (Foundry, yarn).

## Hard Exclusion
**Never access or modify `signals-v0/`** — legacy v0 contracts, excluded from all work.

## Build & Test
```bash
yarn install --frozen-lockfile
forge build                  # compile contracts
forge test -vvv              # run all tests
yarn export-abis             # extract ABIs from Foundry out/ to abis/
yarn lint                    # tsc --noEmit strict check
```

## Key Paths
- `contracts/` — main v1 contracts
- `contracts/interfaces/` — contract interfaces (changes → SDK ABI regen)
- `contracts/lib/` — math libraries (changes → SDK quote sync)
- `script/` — Forge script entrypoints
- `script/base/` — BaseScript.s.sol, Constants.s.sol (shared infrastructure)
- `script/config/` — JSON config files for forge scripts
- `script-output/` — Forge script output JSONs (gitignored)
- `scripts/` — TypeScript utility scripts (verify, safe-propose, export-abis, post-deploy)
- `scripts/_archived/` — Archived legacy scripts
- `releases/` — deployment manifests (dev/prod JSON plans from prepare-safe-upgrade)

## Cross-Repo Impact
- Event signature change → v1-subgraph schema + mappings
- Interface change → v1-sdk ABI regen (`forge build && node scripts/export-abis.js`)
- Math/rounding change → v1-sdk quote logic sync

## Deploy Scripts
- `yarn deploy:dev` — full V1 deployment via forge
- `yarn deploy-fee-policies:dev` / `yarn deploy-fee-policies:prod` — deploy fee policies
- `yarn deploy-impls:dev` / `yarn deploy-impls:prod` — deploy implementation contracts
- `yarn safety-check:dev` / `yarn safety-check:prod` — on-chain verification
- `yarn create-market:dev` — create market (requires config at `script/config/market-dev.json`)
- `yarn close-market:dev` — close/settle market
- `yarn prepare-safe-upgrade:dev` / `yarn prepare-safe-upgrade:prod` — Safe TX calldata for upgrade
- `yarn verify:dev` / `yarn verify:prod` — contract verification via `forge verify-contract`
- `yarn post-deploy <env> <action>` — merge forge output into env JSON

## Style
- OpenZeppelin conventions, NatSpec comments required
- All new functions need happy path + edge case tests
- Bug fixes require regression test

## Git Flow
- Base branch: `main`
