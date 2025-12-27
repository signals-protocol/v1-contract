export type Environment = "localhost" | "citrea-dev" | "citrea-prod";

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
  "localhost": "scripts/environments/localhost.json",
  "citrea-dev": "scripts/environments/citrea-dev.json",
  "citrea-prod": "scripts/environments/citrea-prod.json",
};
