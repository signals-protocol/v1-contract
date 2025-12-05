import fs from "fs";
import path from "path";
import { Environment, EnvironmentFile, ENV_PATHS, DeploymentRecord, EnvironmentContracts } from "../types/environment";

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
      history: [],
    };
    ensureDir(envPath);
    fs.writeFileSync(envPath, JSON.stringify(initial, null, 2));
    return initial;
  }
  const raw = fs.readFileSync(envPath, "utf8");
  return JSON.parse(raw) as EnvironmentFile;
}

export function saveEnvironment(env: Environment, data: EnvironmentFile) {
  const envPath = getEnvironmentPath(env);
  ensureDir(envPath);
  fs.writeFileSync(envPath, JSON.stringify(data, null, 2));
}

export function updateContracts(env: Environment, contracts: EnvironmentContracts) {
  const data = loadEnvironment(env);
  data.contracts = { ...data.contracts, ...contracts };
  saveEnvironment(env, data);
}

export function appendHistory(env: Environment, record: DeploymentRecord) {
  const data = loadEnvironment(env);
  data.history.push(record);
  saveEnvironment(env, data);
}

export function normalizeEnvironment(env: string): Environment {
  if (env.includes(":")) {
    const [base, stage] = env.split(":");
    if (base === "citrea") return (`${base}-${stage}` as Environment);
    return stage as Environment;
  }
  return env as Environment;
}
