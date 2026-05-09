import type { StorageEntry, StorageLayout } from './types';

export type AnnotationTarget = {
  astId?: number;
  label?: string;
  context?: string;
};

export type RenameAnnotationResult = {
  allowed: boolean;
  annotations: string[];
};

export type AnnotationLookup = {
  hasRenameAnnotation(
    target: AnnotationTarget,
    oldLabel: string,
  ): RenameAnnotationResult;
};

type CanonicalEntry = {
  label: string;
  offset: number;
  slot: string;
  type: string;
};

type CanonicalStruct = {
  label: string;
  members: CanonicalEntry[];
};

export type CanonicalStorageLayout = {
  storage: CanonicalEntry[];
  structs: CanonicalStruct[];
};

export type CompareResult = {
  ok: boolean;
  errors: string[];
};

type ReachableStruct = {
  rawType: string;
  label: string;
  members: StorageEntry[];
};

function normalizeUnknownType(typeId: string): string {
  return typeId.replace(
    /\bt_(struct|enum)\(([^)]+)\)\d+(_storage)?\b/g,
    't_$1($2)$3',
  );
}

function typeLabel(layout: StorageLayout, typeId: string): string {
  return layout.types[typeId]?.label ?? normalizeUnknownType(typeId);
}

function referencedTypeIds(layout: StorageLayout, typeId: string): string[] {
  const typeDef = layout.types[typeId];
  if (!typeDef) return [];

  const refs: string[] = [];
  if (typeDef.key) refs.push(typeDef.key);
  if (typeDef.value) refs.push(typeDef.value);
  if (typeDef.base) refs.push(typeDef.base);
  for (const member of typeDef.members ?? []) {
    refs.push(member.type);
  }
  return refs.filter((ref) => Boolean(layout.types[ref]));
}

function reachableStructs(layout: StorageLayout): Map<string, ReachableStruct> {
  const structs = new Map<string, ReachableStruct>();
  const visited = new Set<string>();

  function visit(typeId: string): void {
    if (visited.has(typeId)) return;
    visited.add(typeId);

    const typeDef = layout.types[typeId];
    if (!typeDef) return;

    if (typeDef.members) {
      structs.set(typeLabel(layout, typeId), {
        rawType: typeId,
        label: typeLabel(layout, typeId),
        members: typeDef.members,
      });
    }

    for (const ref of referencedTypeIds(layout, typeId)) {
      visit(ref);
    }
  }

  for (const entry of layout.storage) {
    visit(entry.type);
  }

  return structs;
}

function canonicalEntry(
  layout: StorageLayout,
  entry: StorageEntry,
): CanonicalEntry {
  return {
    label: entry.label,
    offset: entry.offset,
    slot: entry.slot,
    type: typeLabel(layout, entry.type),
  };
}

export function canonicalStorageLayout(
  layout: StorageLayout,
): CanonicalStorageLayout {
  const structs = Array.from(reachableStructs(layout).values())
    .map((struct) => ({
      label: struct.label,
      members: struct.members.map((member) => canonicalEntry(layout, member)),
    }))
    .sort((a, b) => a.label.localeCompare(b.label));

  return {
    storage: layout.storage.map((entry) => canonicalEntry(layout, entry)),
    structs,
  };
}

export function areCanonicalLayoutsEqual(
  left: CanonicalStorageLayout,
  right: CanonicalStorageLayout,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function annotationSummary(result: RenameAnnotationResult): string {
  if (result.annotations.length === 0) return '';
  return ` Found annotation(s): ${result.annotations.join(', ')}.`;
}

function compareEntry(
  contractName: string,
  context: string,
  baselineLayout: StorageLayout,
  currentLayout: StorageLayout,
  baseline: StorageEntry,
  current: StorageEntry,
  annotations: AnnotationLookup,
  errors: string[],
): void {
  if (baseline.slot !== current.slot) {
    errors.push(
      `[FAIL] ${contractName} ${context} slot changed: ${baseline.slot} -> ${current.slot}. Existing slot moves break proxy storage. Append new fields instead.`,
    );
  }

  if (baseline.offset !== current.offset) {
    errors.push(
      `[FAIL] ${contractName} ${context} offset changed: ${baseline.offset} -> ${current.offset}. Existing offset changes break proxy storage.`,
    );
  }

  const baselineType = typeLabel(baselineLayout, baseline.type);
  const currentType = typeLabel(currentLayout, current.type);
  if (baselineType !== currentType) {
    errors.push(
      `[FAIL] ${contractName} ${context} type changed: ${baselineType} -> ${currentType}. Existing slot type changes break proxy storage.`,
    );
  }

  if (baseline.label !== current.label) {
    const annotation = annotations.hasRenameAnnotation(
      {
        astId: current.astId,
        label: current.label,
        context,
      },
      baseline.label,
    );
    if (!annotation.allowed) {
      errors.push(
        `[FAIL] ${contractName} ${context} label ${baseline.label} -> ${current.label} without @custom:oz-renamed-from ${baseline.label}. Add the annotation next to the declaration or revert the label change.${annotationSummary(annotation)}`,
      );
    }
  }
}

function comparePrefix(
  contractName: string,
  location: string,
  baselineLayout: StorageLayout,
  currentLayout: StorageLayout,
  baselineEntries: StorageEntry[],
  currentEntries: StorageEntry[],
  annotations: AnnotationLookup,
  errors: string[],
): void {
  if (currentEntries.length < baselineEntries.length) {
    errors.push(
      `[FAIL] ${contractName} ${location} removed ${baselineEntries.length - currentEntries.length} existing storage entr${baselineEntries.length - currentEntries.length === 1 ? 'y' : 'ies'}. Removing storage breaks proxy layout.`,
    );
  }

  const count = Math.min(baselineEntries.length, currentEntries.length);
  for (let i = 0; i < count; i++) {
    const baseline = baselineEntries[i];
    const current = currentEntries[i];
    const context =
      location === 'storage'
        ? `slot ${baseline.slot}`
        : `${location} member ${i} ${baseline.label}`;
    compareEntry(
      contractName,
      context,
      baselineLayout,
      currentLayout,
      baseline,
      current,
      annotations,
      errors,
    );
  }

  if (
    location === 'storage' &&
    currentEntries.length > baselineEntries.length
  ) {
    // Only entirely new top-level slots after the previous maximum baseline slot
    // are allowed. Shrinking an upgradeable __gap and placing a new variable in
    // the old gap range is intentionally rejected by the existing slot/type
    // comparison plus this append check; see .workflow/plans/SIG-743.md
    // Non-goals for the conservative rationale.
    const lastBaselineSlot = baselineEntries.reduce<bigint | undefined>(
      (maxSlot, entry) => {
        const slot = BigInt(entry.slot);
        return maxSlot === undefined || slot > maxSlot ? slot : maxSlot;
      },
      undefined,
    );

    if (lastBaselineSlot !== undefined) {
      for (const entry of currentEntries.slice(baselineEntries.length)) {
        if (BigInt(entry.slot) <= lastBaselineSlot) {
          errors.push(
            `[FAIL] ${contractName} new top-level field ${entry.label} uses slot ${entry.slot}. Top-level additions must append after existing slot ${lastBaselineSlot.toString()} instead of packing into an existing slot.`,
          );
        }
      }
    }
  }
}

export function compareStorageSafety(
  contractName: string,
  baselineLayout: StorageLayout,
  currentLayout: StorageLayout,
  annotations: AnnotationLookup,
): CompareResult {
  const errors: string[] = [];

  comparePrefix(
    contractName,
    'storage',
    baselineLayout,
    currentLayout,
    baselineLayout.storage,
    currentLayout.storage,
    annotations,
    errors,
  );

  const baselineStructs = reachableStructs(baselineLayout);
  const currentStructs = reachableStructs(currentLayout);

  for (const [label, baselineStruct] of baselineStructs.entries()) {
    const currentStruct = currentStructs.get(label);
    if (!currentStruct) {
      errors.push(
        `[FAIL] ${contractName} ${label} struct is missing from the current reachable storage graph. Existing struct type changes break proxy storage.`,
      );
      continue;
    }

    comparePrefix(
      contractName,
      label,
      baselineLayout,
      currentLayout,
      baselineStruct.members,
      currentStruct.members,
      annotations,
      errors,
    );
  }

  return {
    ok: errors.length === 0,
    errors,
  };
}
