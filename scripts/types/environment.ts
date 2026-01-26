export type Environment =
  | "local"
  | "dev"
  | "testnet"
  | "prod";

export interface DeploymentRecord {
  version: number;
  action: string;
  deployer: string;
  timestamp: number;
  meta?: Record<string, unknown>;
}

export interface EnvironmentContracts {
  [name: string]: string;
}

export interface EnvironmentConfig {
  settlementSubmitWindow?: string;
  settlementFinalizeDeadline?: string;
  pendingOpsWindow?: string;
  defaultFeeBps?: number;
  redstoneFeedId?: string;
  redstoneFeedDecimals?: number;
  redstoneMaxSampleDistance?: string;
  redstoneFutureTolerance?: string;
  lpShareTokenName?: string;
  lpShareTokenSymbol?: string;
  owners?: {
    core?: string;
    position?: string;
  };
}

export interface EnvironmentFile {
  network: Environment;
  version: number;
  contracts: EnvironmentContracts;
  config?: EnvironmentConfig;
  history: DeploymentRecord[];
}

export const ENV_PATHS: Record<Environment, string> = {
  "local": "scripts/environments/local.json",
  "dev": "scripts/environments/dev.json",
  "testnet": "scripts/environments/testnet.json",
  "prod": "scripts/environments/prod.json",
};
