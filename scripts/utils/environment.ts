import fs from "fs";
import path from "path";
import {
  Environment,
  EnvironmentFile,
  EnvironmentConfig,
  ENV_PATHS,
  DeploymentRecord,
  EnvironmentContracts,
} from "../types/environment";

function ensureDir(filePath: string) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

export function getEnvironmentPath(env: Environment): string {
  return ENV_PATHS[env];
}

export function loadEnvironment(env: Environment): EnvironmentFile {
  const envPath = getEnvironmentPath(env);
  if (!fs.existsSync(envPath)) {
    const initial: EnvironmentFile = {
      network: env,
      version: 1,
      contracts: {},
      config: {},
      history: [],
    };
    ensureDir(envPath);
    fs.writeFileSync(envPath, JSON.stringify(initial, null, 2));
    return initial;
  }
  const raw = fs.readFileSync(envPath, "utf8");
  const parsed = JSON.parse(raw) as EnvironmentFile;
  if (!parsed.config) parsed.config = {};
  return parsed;
}

export function saveEnvironment(env: Environment, data: EnvironmentFile) {
  const envPath = getEnvironmentPath(env);
  ensureDir(envPath);
  fs.writeFileSync(envPath, JSON.stringify(data, null, 2));
}

export function updateContracts(env: Environment, contracts: EnvironmentContracts) {
  const data = loadEnvironment(env);
  data.contracts = { ...data.contracts, ...contracts };
  if (contracts.SignalsUSDToken) {
    delete data.contracts.PaymentToken;
  }
  saveEnvironment(env, data);
}

export function updateConfig(env: Environment, config: Partial<EnvironmentConfig>) {
  const data = loadEnvironment(env);
  const existing = data.config ?? {};
  const owners = {
    ...(existing.owners ?? {}),
    ...(config.owners ?? {}),
  };
  data.config = {
    ...existing,
    ...config,
    owners: Object.keys(owners).length ? owners : existing.owners,
  };
  saveEnvironment(env, data);
}

export function recordDeployment(
  env: Environment,
  record: Omit<DeploymentRecord, "version" | "timestamp">
): { data: EnvironmentFile; record: DeploymentRecord } {
  const data = loadEnvironment(env);
  const nextVersion = data.version + 1;
  const entry: DeploymentRecord = {
    ...record,
    version: nextVersion,
    timestamp: Math.floor(Date.now() / 1000),
  };
  data.version = nextVersion;
  data.history.push(entry);
  saveEnvironment(env, data);
  return { data, record: entry };
}

export function normalizeEnvironment(env: string): Environment {
  if (env.includes(":")) {
    const [base, stage] = env.split(":");
    if (base === "citrea") return (`${base}-${stage}` as Environment);
    return stage as Environment;
  }
  return env as Environment;
}
