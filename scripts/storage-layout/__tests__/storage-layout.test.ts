import assert from 'assert';
import fs from 'fs';
import os from 'os';
import path from 'path';
import test from 'node:test';

import {
  type AnnotationLookup,
  areCanonicalLayoutsEqual,
  canonicalStorageLayout,
  compareStorageSafety,
} from '../comparator';
import {
  BuildInfoAnnotationResolver,
  discoverUupsContracts,
  validateTrackedUupsContracts,
} from '../build-info';
import type { StorageLayout, TrackedContract } from '../types';

const uint256 = {
  encoding: 'inplace',
  label: 'uint256',
  numberOfBytes: '32',
};

const uint128 = {
  encoding: 'inplace',
  label: 'uint128',
  numberOfBytes: '16',
};

const uint64 = {
  encoding: 'inplace',
  label: 'uint64',
  numberOfBytes: '8',
};

const int256 = {
  encoding: 'inplace',
  label: 'int256',
  numberOfBytes: '32',
};

const uint32 = {
  encoding: 'inplace',
  label: 'uint32',
  numberOfBytes: '4',
};

const noAnnotations: AnnotationLookup = {
  hasRenameAnnotation() {
    return { allowed: false, annotations: [] };
  },
};

function annotations(entries: Record<number, string[]>): AnnotationLookup {
  return {
    hasRenameAnnotation(target, oldLabel) {
      const labels =
        target.astId === undefined ? [] : (entries[target.astId] ?? []);
      return { allowed: labels.includes(oldLabel), annotations: labels };
    },
  };
}

function topLayout(entries: StorageLayout['storage']): StorageLayout {
  return {
    storage: entries,
    types: {
      t_uint256: uint256,
      t_uint128: uint128,
    },
  };
}

function topVar(
  astId: number,
  label: string,
  slot: string,
  type = 't_uint256',
): StorageLayout['storage'][number] {
  return {
    astId,
    contract: 'contracts/Fixture.sol:Fixture',
    label,
    offset: 0,
    slot,
    type,
  };
}

function marketLayout(
  memberOverrides: Partial<StorageLayout> = {},
): StorageLayout {
  const base: StorageLayout = {
    storage: [
      {
        astId: 10,
        contract: 'contracts/Fixture.sol:Fixture',
        label: 'markets',
        offset: 0,
        slot: '0',
        type: 't_mapping(t_uint256,t_struct(Market)5110_storage)',
      },
    ],
    types: {
      t_uint256: uint256,
      t_uint128: uint128,
      t_uint64: uint64,
      't_mapping(t_uint256,t_struct(Market)5110_storage)': {
        encoding: 'mapping',
        key: 't_uint256',
        label: 'mapping(uint256 => struct ISignalsCore.Market)',
        numberOfBytes: '32',
        value: 't_struct(Market)5110_storage',
      },
      't_struct(Market)5110_storage': {
        encoding: 'inplace',
        label: 'struct ISignalsCore.Market',
        numberOfBytes: '96',
        members: [
          {
            astId: 101,
            contract: 'contracts/interfaces/ISignalsCore.sol:ISignalsCore',
            label: 'startTimestamp',
            offset: 0,
            slot: '0',
            type: 't_uint64',
          },
          {
            astId: 102,
            contract: 'contracts/interfaces/ISignalsCore.sol:ISignalsCore',
            label: 'liquidity',
            offset: 0,
            slot: '1',
            type: 't_uint128',
          },
        ],
      },
    },
  };
  return { ...base, ...memberOverrides };
}

function treeLayout(nodeMemberType = 't_uint128'): StorageLayout {
  return {
    storage: [
      {
        astId: 20,
        contract: 'contracts/Fixture.sol:Fixture',
        label: 'marketTrees',
        offset: 0,
        slot: '0',
        type: 't_mapping(t_uint256,t_struct(Tree)1_storage)',
      },
    ],
    types: {
      t_uint256: uint256,
      t_uint128: uint128,
      t_int256: int256,
      t_uint32: uint32,
      't_mapping(t_uint256,t_struct(Tree)1_storage)': {
        encoding: 'mapping',
        key: 't_uint256',
        label: 'mapping(uint256 => struct LazyMulSegmentTree.Tree)',
        numberOfBytes: '32',
        value: 't_struct(Tree)1_storage',
      },
      't_struct(Tree)1_storage': {
        encoding: 'inplace',
        label: 'struct LazyMulSegmentTree.Tree',
        numberOfBytes: '64',
        members: [
          {
            astId: 201,
            contract: 'contracts/lib/LazyMulSegmentTree.sol:LazyMulSegmentTree',
            label: 'scale',
            offset: 0,
            slot: '0',
            type: 't_uint256',
          },
          {
            astId: 202,
            contract: 'contracts/lib/LazyMulSegmentTree.sol:LazyMulSegmentTree',
            label: 'nodes',
            offset: 0,
            slot: '1',
            type: 't_mapping(t_uint32,t_struct(Node)2_storage)',
          },
        ],
      },
      't_mapping(t_uint32,t_struct(Node)2_storage)': {
        encoding: 'mapping',
        key: 't_uint32',
        label: 'mapping(uint32 => struct LazyMulSegmentTree.Node)',
        numberOfBytes: '32',
        value: 't_struct(Node)2_storage',
      },
      't_struct(Node)2_storage': {
        encoding: 'inplace',
        label: 'struct LazyMulSegmentTree.Node',
        numberOfBytes: '32',
        members: [
          {
            astId: 203,
            contract: 'contracts/lib/LazyMulSegmentTree.sol:LazyMulSegmentTree',
            label: 'lazyMulWad',
            offset: 0,
            slot: '0',
            type: nodeMemberType,
          },
        ],
      },
    },
  };
}

test('identity layouts pass safety comparison', () => {
  const baseline = topLayout([topVar(1, 'first', '0')]);
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    baseline,
    noAnnotations,
  );
  assert.deepStrictEqual(result.errors, []);
});

test('top-level append passes safety comparison', () => {
  const baseline = topLayout([topVar(1, 'first', '0')]);
  const current = topLayout([
    topVar(1, 'first', '0'),
    topVar(2, 'second', '1'),
  ]);
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.deepStrictEqual(result.errors, []);
});

test('top-level packing into an existing slot fails', () => {
  const baseline = topLayout([topVar(1, 'first', '0', 't_uint128')]);
  const current = topLayout([
    topVar(1, 'first', '0', 't_uint128'),
    {
      ...topVar(2, 'packedSecond', '0', 't_uint128'),
      offset: 16,
    },
  ]);
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(result.ok, false);
  assert.match(
    result.errors[0],
    /new top-level field packedSecond uses slot 0/,
  );
});

test('top-level slot, offset, or type change fails with slot info', () => {
  const baseline = topLayout([topVar(1, 'first', '0')]);
  const current = topLayout([topVar(1, 'first', '0', 't_uint128')]);
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(result.ok, false);
  assert.match(result.errors[0], /Fixture slot 0 type changed/);
});

test('top-level label rename passes with oz rename annotation', () => {
  const baseline = topLayout([topVar(1, 'oldName', '0')]);
  const current = topLayout([topVar(2, 'newName', '0')]);
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    annotations({ 2: ['oldName'] }),
  );
  assert.deepStrictEqual(result.errors, []);
});

test('top-level label rename fails without oz rename annotation', () => {
  const baseline = topLayout([topVar(1, 'oldName', '0')]);
  const current = topLayout([topVar(2, 'newName', '0')]);
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(result.ok, false);
  assert.match(
    result.errors[0],
    /oldName -> newName without @custom:oz-renamed-from/,
  );
});

test('struct member append passes safety comparison', () => {
  const baseline = marketLayout();
  const current = marketLayout();
  current.types['t_struct(Market)5110_storage'].members?.push({
    astId: 103,
    contract: 'contracts/interfaces/ISignalsCore.sol:ISignalsCore',
    label: 'volume',
    offset: 16,
    slot: '1',
    type: 't_uint128',
  });
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.deepStrictEqual(result.errors, []);
});

test('struct member reorder fails', () => {
  const baseline = marketLayout();
  const current = marketLayout();
  current.types['t_struct(Market)5110_storage'].members?.reverse();
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(result.ok, false);
  assert.match(
    result.errors[0],
    /struct ISignalsCore\.Market member 0 startTimestamp slot changed/,
  );
});

test('struct member type change fails', () => {
  const baseline = marketLayout();
  const current = marketLayout();
  current.types['t_struct(Market)5110_storage'].members![1].type = 't_uint256';
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(result.ok, false);
  assert.match(
    result.errors[0],
    /struct ISignalsCore\.Market member 1 liquidity type changed/,
  );
});

test('struct member rename passes with oz rename annotation', () => {
  const baseline = marketLayout();
  const current = marketLayout();
  current.types['t_struct(Market)5110_storage'].members![1].label =
    'availableLiquidity';
  current.types['t_struct(Market)5110_storage'].members![1].astId = 155;
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    annotations({ 155: ['liquidity'] }),
  );
  assert.deepStrictEqual(result.errors, []);
});

test('astId-only changes are ignored in canonical equality', () => {
  const baseline = marketLayout();
  const current = marketLayout();
  current.storage[0].astId = 9999;
  current.types['t_struct(Market)5110_storage'].members![0].astId = 9998;
  assert.strictEqual(
    areCanonicalLayoutsEqual(
      canonicalStorageLayout(baseline),
      canonicalStorageLayout(current),
    ),
    true,
  );
});

test('type identifier ast number changes are ignored in canonical equality', () => {
  const baseline = marketLayout();
  const current = marketLayout({
    storage: [
      {
        ...marketLayout().storage[0],
        type: 't_mapping(t_uint256,t_struct(Market)6000_storage)',
      },
    ],
    types: {
      ...marketLayout().types,
      't_mapping(t_uint256,t_struct(Market)6000_storage)': {
        ...marketLayout().types[
          't_mapping(t_uint256,t_struct(Market)5110_storage)'
        ],
        value: 't_struct(Market)6000_storage',
      },
      't_struct(Market)6000_storage': {
        ...marketLayout().types['t_struct(Market)5110_storage'],
      },
    },
  });
  delete current.types['t_mapping(t_uint256,t_struct(Market)5110_storage)'];
  delete current.types['t_struct(Market)5110_storage'];

  assert.strictEqual(
    areCanonicalLayoutsEqual(
      canonicalStorageLayout(baseline),
      canonicalStorageLayout(current),
    ),
    true,
  );
});

test('nested mapping to struct changes are detected recursively', () => {
  const baseline = treeLayout('t_uint128');
  const current = treeLayout('t_int256');
  const result = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(result.ok, false);
  assert.match(
    result.errors[0],
    /struct LazyMulSegmentTree\.Node member 0 lazyMulWad type changed/,
  );
});

test('stale strict equality rejects an append that safety comparison allows', () => {
  const baseline = topLayout([topVar(1, 'first', '0')]);
  const current = topLayout([
    topVar(1, 'first', '0'),
    topVar(2, 'second', '1'),
  ]);
  const safety = compareStorageSafety(
    'Fixture',
    baseline,
    current,
    noAnnotations,
  );
  assert.strictEqual(safety.ok, true);
  assert.strictEqual(
    areCanonicalLayoutsEqual(
      canonicalStorageLayout(baseline),
      canonicalStorageLayout(current),
    ),
    false,
  );
});

function writeBuildInfo(
  root: string,
  name: string,
  sourceContent: string,
  storageLayout: StorageLayout,
  documentation: string | null,
): void {
  const ast = {
    absolutePath: 'contracts/Foo.sol',
    id: 100,
    nodeType: 'SourceUnit',
    nodes: [
      {
        id: 200,
        nodeType: 'ContractDefinition',
        name: 'Foo',
        nodes: [
          {
            id: 7,
            nodeType: 'VariableDeclaration',
            name: 'newName',
            documentation:
              documentation === null
                ? undefined
                : {
                    id: 8,
                    nodeType: 'StructuredDocumentation',
                    text: documentation,
                  },
          },
        ],
      },
    ],
  };
  fs.mkdirSync(path.join(root, 'out/build-info'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'out/build-info', `${name}.json`),
    JSON.stringify({
      input: {
        sources: {
          'contracts/Foo.sol': {
            content: sourceContent,
          },
        },
      },
      output: {
        contracts: {
          'contracts/Foo.sol': {
            Foo: {
              storageLayout,
            },
          },
        },
        sources: {
          'contracts/Foo.sol': {
            ast,
          },
        },
      },
    }),
  );
}

type UupsContractFixture = {
  sourcePath: string;
  name: string;
  id: number;
  bases?: number[];
};

function writeUupsBuildInfo(
  root: string,
  name: string,
  contracts: UupsContractFixture[],
): void {
  const sources: Record<string, { ast: unknown }> = {};
  const inputSources: Record<string, { content: string }> = {};

  for (const contract of contracts) {
    inputSources[contract.sourcePath] = {
      content: `contract ${contract.name} {}`,
    };
    sources[contract.sourcePath] = {
      ast: {
        absolutePath: contract.sourcePath,
        id: contract.id * 10,
        nodeType: 'SourceUnit',
        nodes: [
          {
            id: contract.id,
            nodeType: 'ContractDefinition',
            name: contract.name,
            linearizedBaseContracts: contract.bases,
          },
        ],
      },
    };
  }

  fs.mkdirSync(path.join(root, 'out/build-info'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'out/build-info', `${name}.json`),
    JSON.stringify({
      input: {
        sources: inputSources,
      },
      output: {
        sources,
      },
    }),
  );
}

function tempProject(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'storage-layout-'));
  fs.mkdirSync(path.join(root, 'contracts'), { recursive: true });
  return root;
}

function trackedFoo(): TrackedContract {
  return {
    contractName: 'Foo',
    fqn: 'contracts/Foo.sol:Foo',
    name: 'Foo',
    snapshotPath: 'storage-snapshots/Foo.json',
    sourcePath: 'contracts/Foo.sol',
  };
}

test('build-info annotation lookup first filters by matching storage layout', () => {
  const root = tempProject();
  const source = 'contract Foo { uint256 newName; }';
  fs.writeFileSync(path.join(root, 'contracts/Foo.sol'), source);
  const matchingLayout = topLayout([topVar(7, 'newName', '0')]);
  const differentLayout = topLayout([topVar(7, 'newName', '1')]);
  writeBuildInfo(
    root,
    'wrong-layout',
    source,
    differentLayout,
    '@custom:oz-renamed-from oldName',
  );
  writeBuildInfo(root, 'right-layout', source, matchingLayout, null);

  const resolver = new BuildInfoAnnotationResolver(
    root,
    trackedFoo(),
    matchingLayout,
  );
  const result = resolver.hasRenameAnnotation({ astId: 7 }, 'oldName');
  assert.strictEqual(result.allowed, false);
});

test('build-info annotation lookup uses source-content disambiguation', () => {
  const root = tempProject();
  const staleSource = 'contract Foo { uint256 staleName; }';
  const currentSource = 'contract Foo { uint256 newName; }';
  fs.writeFileSync(path.join(root, 'contracts/Foo.sol'), currentSource);
  const layout = topLayout([topVar(7, 'newName', '0')]);
  writeBuildInfo(root, 'stale', staleSource, layout, null);
  writeBuildInfo(
    root,
    'current',
    currentSource,
    layout,
    '@custom:oz-renamed-from oldName',
  );

  const resolver = new BuildInfoAnnotationResolver(root, trackedFoo(), layout);
  const result = resolver.hasRenameAnnotation({ astId: 7 }, 'oldName');
  assert.strictEqual(result.allowed, true);
});

test('build-info annotation lookup fails when no source content matches', () => {
  const root = tempProject();
  fs.writeFileSync(
    path.join(root, 'contracts/Foo.sol'),
    'contract Foo { uint256 newName; }',
  );
  const layout = topLayout([topVar(7, 'newName', '0')]);
  writeBuildInfo(
    root,
    'stale',
    'contract Foo { uint256 staleName; }',
    layout,
    null,
  );

  const resolver = new BuildInfoAnnotationResolver(root, trackedFoo(), layout);
  assert.throws(
    () => resolver.hasRenameAnnotation({ astId: 7 }, 'oldName'),
    /Stale build-info/,
  );
});

test('UUPS discovery finds direct UUPSUpgradeable inheritance', () => {
  const root = tempProject();
  writeUupsBuildInfo(root, 'direct-uups', [
    {
      sourcePath: 'node_modules/@openzeppelin/UUPSUpgradeable.sol',
      name: 'UUPSUpgradeable',
      id: 1,
    },
    {
      sourcePath: 'contracts/DirectProxy.sol',
      name: 'DirectProxy',
      id: 2,
      bases: [2, 1],
    },
  ]);

  assert.deepStrictEqual(discoverUupsContracts(root), [
    'contracts/DirectProxy.sol:DirectProxy',
  ]);
});

test('UUPS discovery finds transitive UUPSUpgradeable inheritance', () => {
  const root = tempProject();
  writeUupsBuildInfo(root, 'transitive-uups', [
    {
      sourcePath: 'node_modules/@openzeppelin/UUPSUpgradeable.sol',
      name: 'UUPSUpgradeable',
      id: 1,
    },
    {
      sourcePath: 'contracts/BaseProxy.sol',
      name: 'BaseProxy',
      id: 2,
      bases: [2, 1],
    },
    {
      sourcePath: 'contracts/ChildProxy.sol',
      name: 'ChildProxy',
      id: 3,
      bases: [3, 2, 1],
    },
  ]);

  assert.deepStrictEqual(discoverUupsContracts(root), [
    'contracts/BaseProxy.sol:BaseProxy',
    'contracts/ChildProxy.sol:ChildProxy',
  ]);
});

test('UUPS discovery excludes contracts under contracts/testonly', () => {
  const root = tempProject();
  writeUupsBuildInfo(root, 'testonly-uups', [
    {
      sourcePath: 'node_modules/@openzeppelin/UUPSUpgradeable.sol',
      name: 'UUPSUpgradeable',
      id: 1,
    },
    {
      sourcePath: 'contracts/testonly/TestProxy.sol',
      name: 'TestProxy',
      id: 2,
      bases: [2, 1],
    },
  ]);

  assert.deepStrictEqual(discoverUupsContracts(root), []);
});

test('tracked UUPS validation passes when all discovered FQNs are tracked', () => {
  const root = tempProject();
  writeUupsBuildInfo(root, 'tracked-uups', [
    {
      sourcePath: 'node_modules/@openzeppelin/UUPSUpgradeable.sol',
      name: 'UUPSUpgradeable',
      id: 1,
    },
    {
      sourcePath: 'contracts/TrackedProxy.sol',
      name: 'TrackedProxy',
      id: 2,
      bases: [2, 1],
    },
  ]);

  const errors = validateTrackedUupsContracts(root, [
    {
      contractName: 'TrackedProxy',
      fqn: 'contracts/TrackedProxy.sol:TrackedProxy',
      name: 'TrackedProxy',
      snapshotPath: 'storage-snapshots/TrackedProxy.json',
      sourcePath: 'contracts/TrackedProxy.sol',
    },
  ]);

  assert.deepStrictEqual(errors, []);
});

test('tracked UUPS validation fails when a non-testonly UUPS contract is untracked', () => {
  const root = tempProject();
  writeUupsBuildInfo(root, 'untracked-uups', [
    {
      sourcePath: 'node_modules/@openzeppelin/UUPSUpgradeable.sol',
      name: 'UUPSUpgradeable',
      id: 1,
    },
    {
      sourcePath: 'contracts/UntrackedProxy.sol',
      name: 'UntrackedProxy',
      id: 2,
      bases: [2, 1],
    },
  ]);

  const errors = validateTrackedUupsContracts(root, []);

  assert.strictEqual(errors.length, 1);
  assert.match(
    errors[0],
    /Add `contracts\/UntrackedProxy\.sol:UntrackedProxy` to tracked storage list/,
  );
});
