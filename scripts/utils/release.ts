import fs from "fs";
import path from "path";
import { execSync } from "child_process";
import type { Environment, EnvironmentFile } from "../types/environment";

export interface ReleaseMeta extends Record<string, unknown> {
  release?: string;
  gitCommit?: string;
  changes?: string[];
  notes?: string;
}

function sanitizeLabel(label: string): string {
  const cleaned = label.trim().replace(/[^a-zA-Z0-9._-]+/g, "-");
  return cleaned.replace(/^-+|-+$/g, "");
}

function readGitCommit(): string | undefined {
  try {
    return execSync("git rev-parse HEAD", {
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch {
    return undefined;
  }
}

export function buildReleaseMetaFromEnv(): ReleaseMeta | undefined {
  const release = process.env.RELEASE_VERSION;
  const notes = process.env.RELEASE_NOTES;
  const rawChanges = process.env.RELEASE_CHANGES;
  const changes = rawChanges
    ? rawChanges
        .split(",")
        .map((entry) => entry.trim())
        .filter(Boolean)
    : undefined;

  const shouldCheckGit = Boolean(release || notes || (changes && changes.length));
  const gitCommit = process.env.GIT_COMMIT || (shouldCheckGit ? readGitCommit() : undefined);

  if (!release && !notes && !(changes && changes.length) && !gitCommit) return undefined;

  return {
    release,
    notes,
    changes,
    gitCommit,
  };
}

export function writeReleaseSnapshot(
  env: Environment,
  data: EnvironmentFile,
  meta?: ReleaseMeta
): string | undefined {
  if (!meta && process.env.WRITE_RELEASE_SNAPSHOT !== "1") return undefined;

  const dir = path.join("releases", env);
  fs.mkdirSync(dir, { recursive: true });

  const version = String(data.version).padStart(4, "0");
  const label = meta?.release ? sanitizeLabel(meta.release) : "";
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
