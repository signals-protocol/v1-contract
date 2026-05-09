import { execFileSync } from 'child_process';
import fs from 'fs';
import path from 'path';

import {
  BuildInfoAnnotationResolver,
  validateTrackedUupsContracts,
} from './build-info';
import { BASE_REF, TRACKED_CONTRACTS } from './config';
import {
  areCanonicalLayoutsEqual,
  canonicalStorageLayout,
  compareStorageSafety,
} from './comparator';
import type { StorageLayout, TrackedContract } from './types';

const ROOT = path.resolve(__dirname, '../..');
const MAX_BUFFER = 64 * 1024 * 1024;

function runForgeInspect(contract: TrackedContract): StorageLayout {
  const output = execFileSync(
    'forge',
    ['inspect', contract.fqn, 'storageLayout', '--json'],
    {
      cwd: ROOT,
      encoding: 'utf8',
      maxBuffer: MAX_BUFFER,
      stdio: ['ignore', 'pipe', 'inherit'],
    },
  );
  return JSON.parse(output) as StorageLayout;
}

function readJsonFile<T>(filepath: string): T {
  return JSON.parse(fs.readFileSync(filepath, 'utf8')) as T;
}

function writeJsonFile(filepath: string, value: unknown): void {
  fs.mkdirSync(path.dirname(filepath), { recursive: true });
  fs.writeFileSync(filepath, `${JSON.stringify(value, null, 2)}\n`);
}

function gitRefExists(baseRef: string): boolean {
  try {
    execFileSync('git', ['rev-parse', '--verify', `${baseRef}^{commit}`], {
      cwd: ROOT,
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
}

function gitPathExists(baseRef: string, filepath: string): boolean {
  try {
    execFileSync('git', ['cat-file', '-e', `${baseRef}:${filepath}`], {
      cwd: ROOT,
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
}

function readGitJson<T>(baseRef: string, filepath: string): T {
  const output = execFileSync('git', ['show', `${baseRef}:${filepath}`], {
    cwd: ROOT,
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return JSON.parse(output) as T;
}

function isStrictBaseMode(): boolean {
  return process.env.STORAGE_STRICT_BASE === '1' || process.env.CI === 'true';
}

function snapshot(): void {
  for (const contract of TRACKED_CONTRACTS) {
    const layout = runForgeInspect(contract);
    const snapshotPath = path.join(ROOT, contract.snapshotPath);
    writeJsonFile(snapshotPath, layout);
    console.log(`[storage:snapshot] wrote ${contract.snapshotPath}`);
  }
}

function checkBaseAvailability(baseRef: string, strict: boolean): boolean {
  if (gitRefExists(baseRef)) return true;

  const message = `[WARN] Base ref ${baseRef} is not available; skipping base-branch safety diff and running stale checks only.`;
  if (!strict) {
    console.warn(message);
    return false;
  }

  throw new Error(
    `[FAIL] Base ref ${baseRef} is not available. Fetch full history before running storage:check so unsafe storage changes cannot bypass the base snapshot gate.`,
  );
}

function safetyCheck(
  baseRef: string,
  baseAvailable: boolean,
  currentLayouts: Map<string, StorageLayout>,
): string[] {
  const errors: string[] = [];
  if (!baseAvailable) return errors;

  for (const contract of TRACKED_CONTRACTS) {
    if (!gitPathExists(baseRef, contract.snapshotPath)) {
      console.warn(
        `[WARN] ${baseRef}:${contract.snapshotPath} does not exist; skipping ${contract.name} safety diff for initial snapshot rollout.`,
      );
      continue;
    }

    const baseline = readGitJson<StorageLayout>(baseRef, contract.snapshotPath);
    const current = currentLayouts.get(contract.name);
    if (!current) {
      errors.push(
        `[FAIL] Missing current storage layout for ${contract.name}.`,
      );
      continue;
    }

    try {
      const result = compareStorageSafety(
        contract.name,
        baseline,
        current,
        new BuildInfoAnnotationResolver(ROOT, contract, current),
      );
      errors.push(...result.errors);
      if (result.ok) {
        console.log(
          `[storage:check] ${contract.name} is storage-safe relative to ${baseRef}`,
        );
      }
    } catch (error) {
      errors.push(
        error instanceof Error
          ? `[FAIL] ${contract.name} annotation lookup failed: ${error.message}`
          : `[FAIL] ${contract.name} annotation lookup failed.`,
      );
    }
  }

  return errors;
}

function staleCheck(currentLayouts: Map<string, StorageLayout>): string[] {
  const errors: string[] = [];

  for (const contract of TRACKED_CONTRACTS) {
    const snapshotPath = path.join(ROOT, contract.snapshotPath);
    if (!fs.existsSync(snapshotPath)) {
      errors.push(
        `[FAIL] ${contract.snapshotPath} is missing. Run \`yarn storage:snapshot\` and commit the generated baseline.`,
      );
      continue;
    }

    const committed = readJsonFile<StorageLayout>(snapshotPath);
    const current = currentLayouts.get(contract.name);
    if (!current) {
      errors.push(
        `[FAIL] Missing current storage layout for ${contract.name}.`,
      );
      continue;
    }

    if (
      !areCanonicalLayoutsEqual(
        canonicalStorageLayout(committed),
        canonicalStorageLayout(current),
      )
    ) {
      errors.push(
        `[FAIL] ${contract.snapshotPath} is stale. Run \`yarn storage:snapshot\` and commit the updated storage snapshot.`,
      );
      continue;
    }

    console.log(`[storage:check] ${contract.snapshotPath} is fresh`);
  }

  return errors;
}

function check(): void {
  const strict = isStrictBaseMode();
  const currentLayouts = new Map<string, StorageLayout>();

  for (const contract of TRACKED_CONTRACTS) {
    currentLayouts.set(contract.name, runForgeInspect(contract));
  }

  const errors = [
    ...validateTrackedUupsContracts(ROOT, TRACKED_CONTRACTS),
    ...safetyCheck(
      BASE_REF,
      checkBaseAvailability(BASE_REF, strict),
      currentLayouts,
    ),
    ...staleCheck(currentLayouts),
  ];

  if (errors.length > 0) {
    for (const error of errors) {
      console.error(error);
    }
    process.exit(1);
  }

  console.log('[storage:check] storage layouts passed');
}

function main(): void {
  const command = process.argv[2];
  if (command === 'snapshot') {
    snapshot();
    return;
  }
  if (command === 'check') {
    check();
    return;
  }

  console.error('Usage: tsx scripts/storage-layout/index.ts <snapshot|check>');
  process.exit(1);
}

main();
