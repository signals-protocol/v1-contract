export type StorageEntry = {
  astId?: number;
  contract?: string;
  label: string;
  offset: number;
  slot: string;
  type: string;
};

export type StorageType = {
  encoding?: string;
  key?: string;
  value?: string;
  base?: string;
  label: string;
  members?: StorageEntry[];
  numberOfBytes?: string;
  [key: string]: unknown;
};

export type StorageLayout = {
  storage: StorageEntry[];
  types: Record<string, StorageType>;
};

export type TrackedContract = {
  name: string;
  contractName: string;
  sourcePath: string;
  fqn: string;
  snapshotPath: string;
};
