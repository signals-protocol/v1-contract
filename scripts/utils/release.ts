import fs from 'fs';
import path from 'path';
import type { Environment, EnvironmentFile } from '../types/environment';

export interface ReleaseMeta extends Record<string, unknown> {
  release?: string;
  gitCommit?: string;
  changes?: string[];
  notes?: string;
}

function sanitizeLabel(label: string): string {
  const cleaned = label.trim().replace(/[^a-zA-Z0-9._-]+/g, '-');
  return cleaned.replace(/^-+|-+$/g, '');
}

export function writeReleaseSnapshot(
  env: Environment,
  data: EnvironmentFile,
  meta?: ReleaseMeta,
): string | undefined {
  const dir = path.join('releases', env);
  fs.mkdirSync(dir, { recursive: true });

  const version = String(data.version).padStart(4, '0');
  const label = meta?.release ? sanitizeLabel(meta.release) : '';
  const filename = label ? `${version}-${label}.json` : `${version}.json`;
  const snapshot = {
    network: data.network,
    version: data.version,
    contracts: data.contracts,
    config: data.config ?? {},
    history: data.history,
    release: meta,
    generatedAt: new Date().toISOString(),
  };

  const filepath = path.join(dir, filename);
  fs.writeFileSync(filepath, JSON.stringify(snapshot, null, 2));
  return filepath;
}
