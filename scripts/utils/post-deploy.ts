/**
 * post-deploy.ts — Reads forge script output and broadcast JSON, then merges
 * deployed contract addresses, config updates, and library addresses into the
 * environment JSON via existing environment.ts / release.ts functions.
 *
 * Usage:
 *   tsx scripts/utils/post-deploy.ts <env> <action> [--broadcast-dir <path>]
 *
 * Example:
 *   tsx scripts/utils/post-deploy.ts dev deploy-fee-policies
 *   tsx scripts/utils/post-deploy.ts dev deploy --broadcast-dir broadcast/DeployV1.s.sol/5115
 */
import fs from 'fs';
import path from 'path';
import {
  updateContracts,
  updateConfig,
  recordDeployment,
  normalizeEnvironment,
} from './environment';
import { writeReleaseSnapshot } from './release';
import type {
  Environment,
  EnvironmentContracts,
  EnvironmentConfig,
} from '../types/environment';

interface ScriptOutput {
  action: string;
  contracts?: Record<string, string>;
  config?: Partial<EnvironmentConfig>;
  deployer?: string;
}

interface BroadcastTransaction {
  transactionType: string;
  contractName?: string;
  contractAddress?: string;
  function?: string;
}

interface BroadcastJson {
  transactions: BroadcastTransaction[];
  libraries?: string[];
}

function parseArgs(): {
  env: Environment;
  action: string;
  broadcastDir?: string;
} {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.error(
      'Usage: tsx scripts/utils/post-deploy.ts <env> <action> [--broadcast-dir <path>]',
    );
    process.exit(1);
  }

  const env = normalizeEnvironment(args[0]);
  const action = args[1];
  let broadcastDir: string | undefined;

  const bdIdx = args.indexOf('--broadcast-dir');
  if (bdIdx !== -1 && args[bdIdx + 1]) {
    broadcastDir = args[bdIdx + 1];
  }

  return { env, action, broadcastDir };
}

function readScriptOutput(action: string): ScriptOutput | null {
  const outputPath = path.join('script-output', `${action}.json`);
  if (!fs.existsSync(outputPath)) {
    console.warn(`[post-deploy] No script output at ${outputPath}`);
    return null;
  }
  const raw = fs.readFileSync(outputPath, 'utf8');
  return JSON.parse(raw) as ScriptOutput;
}

function readBroadcast(broadcastDir: string): BroadcastJson | null {
  const runLatest = path.join(broadcastDir, 'run-latest.json');
  if (!fs.existsSync(runLatest)) {
    console.warn(`[post-deploy] No broadcast at ${runLatest}`);
    return null;
  }
  const raw = fs.readFileSync(runLatest, 'utf8');
  return JSON.parse(raw) as BroadcastJson;
}

function parseLibraries(libraries: string[]): Record<string, string> {
  const result: Record<string, string> = {};
  for (const lib of libraries) {
    // Format: "contracts/lib/LazyMulSegmentTree.sol:LazyMulSegmentTree:0xAddress"
    const parts = lib.split(':');
    if (parts.length >= 3) {
      const name = parts[parts.length - 2];
      const address = parts[parts.length - 1];
      result[name] = address;
    }
  }
  return result;
}

function main() {
  const { env, action, broadcastDir } = parseArgs();
  console.log(`[post-deploy] env=${env} action=${action}`);

  const scriptOutput = readScriptOutput(action);
  const contracts: EnvironmentContracts = {};
  let config: Partial<EnvironmentConfig> | undefined;
  let deployer: string | undefined;

  // 1. Merge script output contracts
  if (scriptOutput?.contracts) {
    Object.assign(contracts, scriptOutput.contracts);
    console.log(
      `[post-deploy] script output: ${Object.keys(scriptOutput.contracts).length} contracts`,
    );
  }

  // 2. Merge script output config
  if (scriptOutput?.config) {
    config = scriptOutput.config;
  }

  deployer = scriptOutput?.deployer;

  // 3. Parse broadcast for auto-linked libraries
  if (broadcastDir) {
    const broadcast = readBroadcast(broadcastDir);
    if (broadcast?.libraries?.length) {
      const libs = parseLibraries(broadcast.libraries);
      Object.assign(contracts, libs);
      console.log(
        `[post-deploy] broadcast libraries: ${Object.keys(libs).join(', ')}`,
      );
    }
  }

  // 4. Update environment JSON
  if (Object.keys(contracts).length > 0) {
    updateContracts(env, contracts);
    console.log(
      `[post-deploy] updated contracts: ${Object.keys(contracts).join(', ')}`,
    );
  }

  if (config) {
    updateConfig(env, config);
    console.log(`[post-deploy] updated config`);
  }

  // 5. Record deployment and write release snapshot
  const { data: envSnapshot, record } = recordDeployment(env, {
    action,
    deployer: deployer ?? 'unknown',
  });
  writeReleaseSnapshot(env, envSnapshot);

  console.log(`[post-deploy] completed (version=${record.version})`);
}

main();
