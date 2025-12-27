# Signals v1 Contract Ops

## Environments

- `citrea-dev` and `citrea-prod` share chainId `5115`.
- OpenZeppelin manifest is split per env via `MANIFEST_DEFAULT_DIR`:
  - `.openzeppelin/dev` for `citrea-dev`
  - `.openzeppelin/prod` for `citrea-prod`
- Dispatcher enforces `COMMAND` env matches `--network` and the correct manifest dir.

## Sources of Truth

- `scripts/environments/*.json`: current addresses and config.
- `.openzeppelin/*`: upgrade safety manifests (must stay in sync per env).
- `releases/<env>/`: release snapshots (optional but recommended for prod).

## Commands

### Genesis deploy

```bash
yarn deploy:citrea:dev
yarn verify:citrea:dev
yarn safety-check:citrea:dev

yarn deploy:citrea:prod
yarn verify:citrea:prod
yarn safety-check:citrea:prod
```

### Proxy upgrade

```bash
yarn upgrade:citrea:dev
yarn verify:citrea:dev
yarn safety-check:citrea:dev

yarn upgrade:citrea:prod
yarn verify:citrea:prod
yarn safety-check:citrea:prod
```

### Module update (hot swap)

```bash
# default: trade + lifecycle + oracle
yarn update-modules:citrea:dev

# override modules: trade, lifecycle, oracle, risk, vault
MODULES=trade,oracle yarn update-modules:citrea:prod
```

## Release Flow (dev -> prod)

1. `yarn test`
2. `yarn safety-check:citrea:dev`
3. `yarn upgrade:citrea:dev` or `yarn update-modules:citrea:dev`
4. `yarn verify:citrea:dev`
5. Smoke tests
6. `yarn safety-check:citrea:prod`
7. `yarn upgrade:citrea:prod` or `yarn update-modules:citrea:prod`
8. `yarn verify:citrea:prod`
9. `yarn safety-check:citrea:prod`
10. Commit:
    - `scripts/environments/citrea-prod.json`
    - `.openzeppelin/prod/**`
    - `releases/citrea-prod/*.json` (if generated)

## Release Metadata (optional)

Pass these env vars to stamp history + snapshot files:

- `RELEASE_VERSION` (e.g., `v1.2.0`)
- `RELEASE_NOTES`
- `RELEASE_CHANGES` (comma-separated)
- `GIT_COMMIT` (optional override)
- `WRITE_RELEASE_SNAPSHOT=1` (force snapshot even without release version)

Example:

```bash
RELEASE_VERSION=v1.2.0 RELEASE_CHANGES=SignalsCoreImplementation,SignalsPositionImplementation \
  yarn upgrade:citrea:prod
```

## Safety Check Coverage

- Proxy → implementation match (ERC1967)
- Owners (from env config)
- Module addresses and code presence
- Core <-> Position linkage
- Payment token + settlement windows (from env config)
