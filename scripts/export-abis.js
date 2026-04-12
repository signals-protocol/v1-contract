#!/usr/bin/env node
// Extracts normalized ABI files from Hardhat or Foundry build artifacts.
// Output: abis/<ContractName>.json with { contractName, abi, bytecode?, deployedBytecode? }

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'abis');

// Contracts to export: [name, sourceDir, mode]
// sourceDir is only used for Hardhat path resolution (Foundry uses flat out/<Name>.sol/<Name>.json)
const CONTRACTS = [
  ['SignalsCore',              'core',       'full'],
  ['SignalsRouter',            'router',     'full'],
  ['SignalsPosition',          'position',   'full'],
  ['SignalsCoreHarness',       'testonly',   'full'],
  ['SignalsUSDToken',          'testonly',   'full'],
  ['SignalsLPShare',           'tokens',     'full'],
  ['MarketLifecycleModule',    'modules',    'full'],
  ['TradeModule',              'modules',    'full'],
  ['OracleModule',             'modules',    'full'],
  ['LPVaultModule',            'modules',    'full'],
  ['NullFeePolicy',            'fees',       'full'],
  ['MockFeePolicy',            'testonly',   'full'],
  ['MockPercentageFeePolicy',  'testonly',   'full'],
  ['MockCustomFeePolicy',      'testonly',   'full'],
  ['ThetaTimeFeePolicy',       'fees',       'full'],
  ['SeedData',                 'utils',      'full'],
  ['IFeePolicy',               'interfaces', 'abi-only'],
];

// Auto-detect build tool: Foundry (out/) takes priority over Hardhat (artifacts/)
function detectArtifactSource() {
  const foundryDir = path.join(ROOT, 'out');
  const hardhatDir = path.join(ROOT, 'artifacts');

  if (fs.existsSync(foundryDir)) return 'foundry';
  if (fs.existsSync(hardhatDir)) return 'hardhat';

  console.error('Error: No artifact directory found. Run `forge build` or `yarn hardhat compile` first.');
  process.exit(1);
}

function resolveArtifactPath(name, sourceDir, source) {
  if (source === 'foundry') {
    return path.join(ROOT, 'out', `${name}.sol`, `${name}.json`);
  }
  // Hardhat: artifacts/contracts/<sourceDir>/<Name>.sol/<Name>.json
  return path.join(ROOT, 'artifacts', 'contracts', sourceDir, `${name}.sol`, `${name}.json`);
}

function normalizeBytecode(bytecode) {
  if (!bytecode) return undefined;
  // Foundry nests bytecode under .object; Hardhat uses flat string
  if (typeof bytecode === 'object' && bytecode.object) return bytecode.object;
  if (typeof bytecode === 'string') return bytecode;
  return undefined;
}

function main() {
  const source = detectArtifactSource();
  console.log(`Artifact source: ${source}`);

  if (!fs.existsSync(OUT_DIR)) {
    fs.mkdirSync(OUT_DIR, { recursive: true });
  }

  let count = 0;
  for (const [name, sourceDir, mode] of CONTRACTS) {
    const artifactPath = resolveArtifactPath(name, sourceDir, source);

    if (!fs.existsSync(artifactPath)) {
      console.error(`Error: Artifact not found: ${artifactPath}`);
      process.exit(1);
    }

    const raw = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));

    const normalized = { contractName: name, abi: raw.abi };

    if (mode === 'full') {
      const bytecode = normalizeBytecode(raw.bytecode);
      const deployedBytecode = normalizeBytecode(raw.deployedBytecode);
      if (bytecode) normalized.bytecode = bytecode;
      if (deployedBytecode) normalized.deployedBytecode = deployedBytecode;
    }

    const outPath = path.join(OUT_DIR, `${name}.json`);
    fs.writeFileSync(outPath, JSON.stringify(normalized, null, 2) + '\n');
    count++;
  }

  console.log(`Exported ${count} ABI files to abis/`);
}

main();
