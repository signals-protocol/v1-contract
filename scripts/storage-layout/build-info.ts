import fs from 'fs';
import path from 'path';

import type {
  AnnotationLookup,
  AnnotationTarget,
  RenameAnnotationResult,
} from './comparator';
import type { StorageLayout, TrackedContract } from './types';

type JsonObject = Record<string, unknown>;

type BuildInfo = {
  input?: {
    sources?: Record<string, { content?: string }>;
  };
  output?: {
    contracts?: Record<
      string,
      Record<string, { storageLayout?: StorageLayout }>
    >;
    sources?: Record<string, { ast?: JsonObject }>;
  };
};

type BuildInfoCandidate = {
  filepath: string;
  data: BuildInfo;
};

type AstNodeHit = {
  sourcePath: string;
  node: JsonObject;
};

function readJsonFile<T>(filepath: string): T {
  return JSON.parse(fs.readFileSync(filepath, 'utf8')) as T;
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(',')}]`;
  }
  if (value && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(object[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function storageLayoutsEqual(
  left: StorageLayout,
  right: StorageLayout,
): boolean {
  return stableStringify(left) === stableStringify(right);
}

function buildInfoFiles(root: string): string[] {
  const dir = path.join(root, 'out/build-info');
  if (!fs.existsSync(dir)) {
    throw new Error(
      'Stale build-info: out/build-info is missing. Run `forge clean && forge build` and retry.',
    );
  }
  return fs
    .readdirSync(dir)
    .filter((filename) => filename.endsWith('.json'))
    .map((filename) => path.join(dir, filename));
}

function loadBuildInfos(root: string): BuildInfoCandidate[] {
  return buildInfoFiles(root).map((filepath) => ({
    filepath,
    data: readJsonFile<BuildInfo>(filepath),
  }));
}

function matchingBuildInfos(
  root: string,
  contract: TrackedContract,
  layout: StorageLayout,
): BuildInfoCandidate[] {
  return loadBuildInfos(root).filter((candidate) => {
    const candidateLayout =
      candidate.data.output?.contracts?.[contract.sourcePath]?.[
        contract.contractName
      ]?.storageLayout;
    return Boolean(
      candidateLayout && storageLayoutsEqual(candidateLayout, layout),
    );
  });
}

function findNodeById(root: unknown, astId: number): JsonObject | undefined {
  if (!root || typeof root !== 'object') return undefined;
  const node = root as JsonObject;
  if (node.id === astId) return node;

  for (const value of Object.values(node)) {
    if (Array.isArray(value)) {
      for (const item of value) {
        const result = findNodeById(item, astId);
        if (result) return result;
      }
    } else if (value && typeof value === 'object') {
      const result = findNodeById(value, astId);
      if (result) return result;
    }
  }

  return undefined;
}

function findAstNode(
  candidate: BuildInfoCandidate,
  astId: number,
): AstNodeHit | undefined {
  for (const [sourcePath, source] of Object.entries(
    candidate.data.output?.sources ?? {},
  )) {
    const node = findNodeById(source.ast, astId);
    if (node) {
      return { sourcePath, node };
    }
  }
  return undefined;
}

function sourceContentMatches(
  root: string,
  candidate: BuildInfoCandidate,
  sourcePath: string,
): boolean {
  const buildContent = candidate.data.input?.sources?.[sourcePath]?.content;
  if (typeof buildContent !== 'string') return false;

  const workingPath = path.join(root, sourcePath);
  if (!fs.existsSync(workingPath)) return false;

  return fs.readFileSync(workingPath, 'utf8') === buildContent;
}

function documentationText(node: JsonObject): string {
  const documentation = node.documentation;
  if (typeof documentation === 'string') return documentation;
  if (
    documentation &&
    typeof documentation === 'object' &&
    typeof (documentation as JsonObject).text === 'string'
  ) {
    return (documentation as { text: string }).text;
  }
  return '';
}

function renamedFromAnnotations(node: JsonObject): string[] {
  const text = documentationText(node);
  const labels: string[] = [];
  const pattern = /@custom:oz-renamed-from\s+([A-Za-z0-9_$]+)/g;
  let match = pattern.exec(text);
  while (match) {
    labels.push(match[1]);
    match = pattern.exec(text);
  }
  return labels;
}

export class BuildInfoAnnotationResolver implements AnnotationLookup {
  private readonly candidates: BuildInfoCandidate[];

  constructor(
    private readonly root: string,
    private readonly contract: TrackedContract,
    layout: StorageLayout,
  ) {
    this.candidates = matchingBuildInfos(root, contract, layout);
  }

  hasRenameAnnotation(
    target: AnnotationTarget,
    oldLabel: string,
  ): RenameAnnotationResult {
    if (target.astId === undefined) {
      return { allowed: false, annotations: [] };
    }

    if (this.candidates.length === 0) {
      throw new Error(
        `Stale build-info: no build-info storageLayout matches ${this.contract.fqn}. Run \`forge clean && forge build\` and retry.`,
      );
    }

    const matchingSource: AstNodeHit[] = [];
    for (const candidate of this.candidates) {
      const hit = findAstNode(candidate, target.astId);
      if (!hit) continue;
      if (sourceContentMatches(this.root, candidate, hit.sourcePath)) {
        matchingSource.push(hit);
      }
    }

    if (matchingSource.length === 0) {
      throw new Error(
        `Stale build-info: ${this.contract.fqn} astId ${target.astId} does not resolve against current source content. Run \`forge clean && forge build\` and retry.`,
      );
    }

    const labels = renamedFromAnnotations(matchingSource[0].node);
    return {
      allowed: labels.includes(oldLabel),
      annotations: labels,
    };
  }
}

type ContractDefinition = JsonObject & {
  id: number;
  name: string;
  nodeType: 'ContractDefinition';
  linearizedBaseContracts?: number[];
};

function collectContractDefinitions(
  sourcePath: string,
  node: unknown,
  contracts: Map<number, { sourcePath: string; node: ContractDefinition }>,
): void {
  if (!node || typeof node !== 'object') return;
  const object = node as JsonObject;
  if (
    object.nodeType === 'ContractDefinition' &&
    typeof object.id === 'number' &&
    typeof object.name === 'string'
  ) {
    contracts.set(object.id, {
      sourcePath,
      node: object as ContractDefinition,
    });
  }

  for (const value of Object.values(object)) {
    if (Array.isArray(value)) {
      for (const item of value) {
        collectContractDefinitions(sourcePath, item, contracts);
      }
    } else if (value && typeof value === 'object') {
      collectContractDefinitions(sourcePath, value, contracts);
    }
  }
}

export function discoverUupsContracts(root: string): string[] {
  const discovered = new Set<string>();

  for (const buildInfo of loadBuildInfos(root)) {
    const definitions = new Map<
      number,
      { sourcePath: string; node: ContractDefinition }
    >();
    for (const [sourcePath, source] of Object.entries(
      buildInfo.data.output?.sources ?? {},
    )) {
      collectContractDefinitions(sourcePath, source.ast, definitions);
    }

    const uupsIds = new Set(
      Array.from(definitions.entries())
        .filter(([, definition]) => definition.node.name === 'UUPSUpgradeable')
        .map(([id]) => id),
    );

    for (const definition of definitions.values()) {
      if (!definition.sourcePath.startsWith('contracts/')) continue;
      if (definition.sourcePath.startsWith('contracts/testonly/')) continue;

      const bases = definition.node.linearizedBaseContracts ?? [];
      if (!bases.some((baseId) => uupsIds.has(baseId))) continue;

      discovered.add(`${definition.sourcePath}:${definition.node.name}`);
    }
  }

  return Array.from(discovered).sort();
}

export function validateTrackedUupsContracts(
  root: string,
  tracked: TrackedContract[],
): string[] {
  const trackedFqns = new Set(tracked.map((contract) => contract.fqn));
  const discoveredFqns = new Set(discoverUupsContracts(root));
  const errors: string[] = [];

  for (const fqn of discoveredFqns) {
    if (!trackedFqns.has(fqn)) {
      errors.push(
        `[FAIL] ${fqn} inherits UUPSUpgradeable but is not tracked by storage snapshots. Add it to scripts/storage-layout/config.ts or mark it as testonly/untracked.`,
      );
    }
  }

  for (const fqn of trackedFqns) {
    if (!discoveredFqns.has(fqn)) {
      errors.push(
        `[FAIL] ${fqn} is tracked for storage snapshots but was not discovered as a non-testonly UUPS contract. Check the tracked contract list or rebuild artifacts.`,
      );
    }
  }

  return errors;
}
