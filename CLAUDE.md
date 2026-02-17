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
- `scripts/dispatcher.ts` — deploy/upgrade entrypoint
- `deploy/` — deployment manifests

## Cross-Repo Impact
- Event signature change → v1-subgraph schema + mappings
- Interface change → v1-sdk ABI regen (`npx hardhat typechain`)
- Math/rounding change → v1-sdk quote logic sync
- Use `/cross-impact` for detailed analysis

## Deploy Scripts
- `yarn deploy:dev` / `yarn deploy:prod` — contract deployment
- `yarn upgrade:dev` / `yarn upgrade:prod` — proxy upgrade
- `yarn safety-check:dev` / `yarn safety-check:prod` — post-deploy verification

## Style
- OpenZeppelin conventions, NatSpec comments required
- All new functions need happy path + edge case tests
- Bug fixes require regression test

## Git Flow
- Base branch: `main`
