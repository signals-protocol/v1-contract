import type { TrackedContract } from './types';

export const BASE_REF = process.env.STORAGE_BASE_REF ?? 'origin/main';

export const TRACKED_CONTRACTS: TrackedContract[] = [
  {
    contractName: 'SignalsCore',
    sourcePath: 'contracts/core/SignalsCore.sol',
    fqn: 'contracts/core/SignalsCore.sol:SignalsCore',
    snapshotPath: 'storage-snapshots/SignalsCore.json',
  },
  {
    contractName: 'SignalsPosition',
    sourcePath: 'contracts/position/SignalsPosition.sol',
    fqn: 'contracts/position/SignalsPosition.sol:SignalsPosition',
    snapshotPath: 'storage-snapshots/SignalsPosition.json',
  },
  {
    contractName: 'SignalsLPShare',
    sourcePath: 'contracts/tokens/SignalsLPShare.sol',
    fqn: 'contracts/tokens/SignalsLPShare.sol:SignalsLPShare',
    snapshotPath: 'storage-snapshots/SignalsLPShare.json',
  },
];
