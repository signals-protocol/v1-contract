/**
 * General-purpose Safe multisig CLI for Citrea.
 *
 * Usage:
 *   tsx scripts/ops/safe.ts <env> <command> [flags]
 *
 * Commands:
 *   info                              Show Safe info (owners, threshold, nonce)
 *   pending                           List pending transactions
 *   propose --to <addr> --data <hex>  Propose a transaction (with simulation)
 *   propose --batch '<json>'          Propose a batch transaction (MultiSend)
 *   reject  --nonce <n>               Reject a pending transaction
 *   propose-upgrade [--plan <path>]   Propose from latest upgrade plan JSON
 *
 * Flags:
 *   --value <wei>       ETH value (default "0")
 *   --safe <addr>       Override Safe address
 *   --json              JSON output
 *   --no-simulate       Skip simulation (emergency only)
 */

import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { createPublicClient, http, defineChain, type PublicClient } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import Safe from '@safe-global/protocol-kit';
import SafeApiKit from '@safe-global/api-kit';
import { loadEnvironment, normalizeEnvironment } from '../utils/environment';

// ── Constants ───────────────────────────────────────────────

const TX_SERVICE_URL: Record<string, string> = {
  dev: 'https://transaction-testnet.safe.citrea.xyz/api',
  prod: 'https://transaction.safe.citrea.xyz/api',
};

const CHAIN_ID: Record<string, bigint> = {
  dev: 5115n,
  prod: 4114n,
};

const CHAIN_RPC: Record<string, string> = {
  dev: 'https://rpc.testnet.citrea.xyz',
  prod: 'https://rpc.mainnet.citrea.xyz',
};

const citreaDev = defineChain({
  id: 5115,
  name: 'Citrea Testnet',
  nativeCurrency: { name: 'cBTC', symbol: 'cBTC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.citrea.xyz'] } },
});

const citreaProd = defineChain({
  id: 4114,
  name: 'Citrea',
  nativeCurrency: { name: 'cBTC', symbol: 'cBTC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.mainnet.citrea.xyz'] } },
});

// Safe v1.4.1 standard deployment addresses (deterministic, same on all chains).
// Citrea is not in the SDK's built-in registry, so we must provide these explicitly.
const SAFE_CONTRACT_NETWORKS: Record<string, Record<string, string>> = {
  '5115': {
    safeSingletonAddress: '0x29fcB43b46531BcA003ddC8FCB67FFE91900C762',
    safeProxyFactoryAddress: '0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67',
    multiSendAddress: '0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526',
    multiSendCallOnlyAddress: '0x9641d764fc13c8B624c04430C7356C1C7C8102e2',
    fallbackHandlerAddress: '0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99',
    signMessageLibAddress: '0xd53cd0aB83D845Ac265BE939c57F53AD838012c9',
    createCallAddress: '0x9b35Af71d77eaf8d7e40252370304687390A1A52',
    simulateTxAccessorAddress: '0x3d4BA2E0884aa488718476ca2FB8Efc291A46199',
  },
  '4114': {
    safeSingletonAddress: '0x29fcB43b46531BcA003ddC8FCB67FFE91900C762',
    safeProxyFactoryAddress: '0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67',
    multiSendAddress: '0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526',
    multiSendCallOnlyAddress: '0x9641d764fc13c8B624c04430C7356C1C7C8102e2',
    fallbackHandlerAddress: '0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99',
    signMessageLibAddress: '0xd53cd0aB83D845Ac265BE939c57F53AD838012c9',
    createCallAddress: '0x9b35Af71d77eaf8d7e40252370304687390A1A52',
    simulateTxAccessorAddress: '0x3d4BA2E0884aa488718476ca2FB8Efc291A46199',
  },
};

// ── Arg Parsing ─────────────────────────────────────────────

function parseFlag(args: string[], name: string): string | undefined {
  const idx = args.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= args.length) return undefined;
  return args[idx + 1];
}

function hasFlag(args: string[], name: string): boolean {
  return args.includes(`--${name}`);
}

// ── Shared Setup ────────────────────────────────────────────

interface Config {
  env: string;
  chainId: bigint;
  rpcUrl: string;
  txServiceUrl: string;
  safeAddress: string;
}

function resolveConfig(env: string, args: string[]): Config {
  const chainId = CHAIN_ID[env];
  const rpcUrl = CHAIN_RPC[env];
  const txServiceUrl = TX_SERVICE_URL[env];
  if (!chainId || !rpcUrl || !txServiceUrl) {
    throw new Error(`Only dev/prod supported (no TX Service for ${env})`);
  }

  const safeOverride = parseFlag(args, 'safe');
  let safeAddress = safeOverride;
  if (!safeAddress) {
    const envData = loadEnvironment(normalizeEnvironment(env));
    safeAddress = envData.config?.owners?.core;
    if (!safeAddress) {
      throw new Error(
        'No Safe address found in environment config (owners.core). Use --safe <addr>',
      );
    }
  }

  return { env, chainId, rpcUrl, txServiceUrl, safeAddress };
}

function resolveProposerKey(): string {
  const key =
    process.env.SAFE_PROPOSER_KEY?.trim() || process.env.DEPLOYER_KEY?.trim();
  if (!key) {
    throw new Error(
      'Set DEPLOYER_KEY in v1-contract/.env (or SAFE_PROPOSER_KEY)',
    );
  }
  return key;
}

function initApiKit(config: Config): SafeApiKit {
  return new SafeApiKit({
    chainId: config.chainId,
    txServiceUrl: config.txServiceUrl,
  });
}

async function initProtocolKit(
  config: Config,
  proposerKey: string,
): Promise<Safe> {
  const chainIdStr = config.chainId.toString();
  const protocolKit = await Safe.init({
    provider: config.rpcUrl,
    signer: proposerKey,
    safeAddress: config.safeAddress,
    contractNetworks: SAFE_CONTRACT_NETWORKS[chainIdStr]
      ? { [chainIdStr]: SAFE_CONTRACT_NETWORKS[chainIdStr] }
      : undefined,
  });

  const proposer = privateKeyToAccount(proposerKey as `0x${string}`);
  const isOwner = await protocolKit.isOwner(proposer.address);
  if (!isOwner) {
    const info = await initApiKit(config).getSafeInfo(config.safeAddress);
    throw new Error(
      `Address ${proposer.address} is not a Safe owner.\nOwners: ${info.owners.join(', ')}`,
    );
  }

  return protocolKit;
}

function createViemClient(env: string): PublicClient {
  return createPublicClient({
    chain: env === 'dev' ? citreaDev : citreaProd,
    transport: http(),
  });
}

// ── Simulation ──────────────────────────────────────────────

function extractRevertReason(err: unknown): string {
  if (err && typeof err === 'object') {
    const e = err as Record<string, unknown>;
    // viem BaseError chain
    if (e.cause && typeof e.cause === 'object') {
      const cause = e.cause as Record<string, unknown>;
      if (typeof cause.reason === 'string') return cause.reason;
      if (typeof cause.message === 'string') return cause.message;
      // nested cause
      if (cause.cause && typeof cause.cause === 'object') {
        const inner = cause.cause as Record<string, unknown>;
        if (typeof inner.reason === 'string') return inner.reason;
        if (typeof inner.message === 'string') return inner.message;
      }
    }
    if (typeof e.shortMessage === 'string') return e.shortMessage;
    if (typeof e.message === 'string') return e.message;
  }
  return String(err);
}

interface TxInput {
  to: string;
  data: string;
  value: string;
}

async function simulateTx(
  client: PublicClient,
  safeAddress: string,
  transactions: TxInput[],
  isBatch: boolean,
): Promise<{ success: boolean; error?: string; failedIndex?: number }> {
  if (isBatch && transactions.length > 1) {
    console.log(
      'Note: batch simulation runs each TX independently — cross-TX dependencies may not be caught',
    );
  }

  for (let i = 0; i < transactions.length; i++) {
    const tx = transactions[i];
    try {
      await client.call({
        account: safeAddress as `0x${string}`,
        to: tx.to as `0x${string}`,
        data: (tx.data && tx.data !== '0x' ? tx.data : undefined) as
          | `0x${string}`
          | undefined,
        value: BigInt(tx.value || '0'),
      });
    } catch (err) {
      return {
        success: false,
        error: extractRevertReason(err),
        failedIndex: i,
      };
    }
  }
  return { success: true };
}

// ── Propose ─────────────────────────────────────────────────

async function proposeTx(
  protocolKit: Safe,
  apiKit: SafeApiKit,
  transactions: TxInput[],
  config: Config,
  proposerAddress: string,
): Promise<string> {
  const safeTx = await protocolKit.createTransaction({
    transactions: transactions.map((tx) => ({
      to: tx.to,
      data: tx.data || '0x',
      value: tx.value || '0',
    })),
  });

  const safeTxHash = await protocolKit.getTransactionHash(safeTx);
  const signature = await protocolKit.signHash(safeTxHash);

  await apiKit.proposeTransaction({
    safeAddress: config.safeAddress,
    safeTransactionData: safeTx.data,
    safeTxHash,
    senderAddress: proposerAddress,
    senderSignature: signature.data,
    origin: 'signals-safe-cli',
  });

  return safeTxHash;
}

// ── Commands ────────────────────────────────────────────────

async function handleInfo(config: Config, args: string[]) {
  const apiKit = initApiKit(config);
  const info = await apiKit.getSafeInfo(config.safeAddress);
  const nextNonce = await apiKit.getNextNonce(config.safeAddress);

  if (hasFlag(args, 'json')) {
    console.log(JSON.stringify({ ...info, nextNonce }, null, 2));
    return;
  }

  console.log(`Safe: ${info.address}`);
  console.log(`Version: ${info.version}`);
  console.log(`Threshold: ${info.threshold}`);
  console.log(`Owners (${info.owners.length}):`);
  for (const owner of info.owners) {
    console.log(`  ${owner}`);
  }
  console.log(`Nonce: ${info.nonce} (next: ${nextNonce})`);
  if (info.modules.length) {
    console.log(`Modules: ${info.modules.join(', ')}`);
  }
}

async function handlePending(config: Config, args: string[]) {
  const apiKit = initApiKit(config);
  const pending = await apiKit.getPendingTransactions(config.safeAddress);

  if (hasFlag(args, 'json')) {
    console.log(JSON.stringify(pending.results, null, 2));
    return;
  }

  if (!pending.results.length) {
    console.log('No pending transactions.');
    return;
  }

  console.log(`Pending transactions (${pending.results.length}):\n`);
  for (const tx of pending.results) {
    const dataPreview = tx.data ? tx.data.slice(0, 10) : '0x';
    const confirmations = tx.confirmations?.length ?? 0;
    console.log(`  nonce=${tx.nonce} to=${tx.to} data=${dataPreview}...`);
    console.log(
      `    confirmations=${confirmations}/${tx.confirmationsRequired} submitted=${tx.submissionDate}`,
    );
    console.log(`    safeTxHash=${tx.safeTxHash}`);
    console.log();
  }
}

async function handlePropose(config: Config, args: string[]) {
  const proposerKey = resolveProposerKey();
  const proposer = privateKeyToAccount(proposerKey as `0x${string}`);
  const protocolKit = await initProtocolKit(config, proposerKey);
  const apiKit = initApiKit(config);

  // Parse transactions
  let transactions: TxInput[];
  let isBatch = false;
  const batchJson = parseFlag(args, 'batch');

  if (batchJson) {
    isBatch = true;
    try {
      transactions = JSON.parse(batchJson) as TxInput[];
      if (!Array.isArray(transactions) || transactions.length === 0) {
        throw new Error('--batch must be a non-empty JSON array');
      }
    } catch (err) {
      throw new Error(
        `Invalid --batch JSON: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  } else {
    const to = parseFlag(args, 'to');
    const data = parseFlag(args, 'data');
    if (!to) throw new Error('--to is required');
    if (!data) throw new Error('--data is required');
    const value = parseFlag(args, 'value') || '0';
    transactions = [{ to, data, value }];
  }

  // Simulate
  if (!hasFlag(args, 'no-simulate')) {
    const client = createViemClient(config.env);
    console.log('Simulating...');
    const result = await simulateTx(
      client,
      config.safeAddress,
      transactions,
      isBatch,
    );

    if (!result.success) {
      const idx =
        result.failedIndex !== undefined ? ` (tx #${result.failedIndex})` : '';
      console.error(`\nSimulation FAILED${idx}: ${result.error}`);
      console.error('Transaction NOT proposed.');
      process.exit(1);
    }
    console.log('Simulation passed.');
  } else {
    console.log('WARNING: simulation skipped (--no-simulate)');
  }

  // Propose
  console.log('Proposing...');
  const safeTxHash = await proposeTx(
    protocolKit,
    apiKit,
    transactions,
    config,
    proposer.address,
  );

  if (hasFlag(args, 'json')) {
    console.log(
      JSON.stringify({
        safeTxHash,
        safeAddress: config.safeAddress,
        transactions,
        env: config.env,
      }),
    );
  } else {
    console.log(`\nProposed! safeTxHash=${safeTxHash}`);
    console.log(`Safe: ${config.safeAddress}`);
    console.log(`Go to safe.citrea.xyz to sign & execute.`);
  }
}

async function handleReject(config: Config, args: string[]) {
  const proposerKey = resolveProposerKey();
  const proposer = privateKeyToAccount(proposerKey as `0x${string}`);
  const protocolKit = await initProtocolKit(config, proposerKey);
  const apiKit = initApiKit(config);

  const nonceStr = parseFlag(args, 'nonce');
  if (!nonceStr) throw new Error('--nonce is required');
  const nonce = parseInt(nonceStr, 10);
  if (isNaN(nonce)) throw new Error(`Invalid nonce: ${nonceStr}`);

  // No simulation needed — rejection is always a 0-value self-transfer
  console.log(`Proposing rejection for nonce ${nonce}...`);
  const rejectionTx = await protocolKit.createRejectionTransaction(nonce);
  const safeTxHash = await protocolKit.getTransactionHash(rejectionTx);
  const signature = await protocolKit.signHash(safeTxHash);

  await apiKit.proposeTransaction({
    safeAddress: config.safeAddress,
    safeTransactionData: rejectionTx.data,
    safeTxHash,
    senderAddress: proposer.address,
    senderSignature: signature.data,
    origin: 'signals-safe-cli',
  });

  if (hasFlag(args, 'json')) {
    console.log(JSON.stringify({ safeTxHash, nonce, action: 'reject' }));
  } else {
    console.log(`\nRejection proposed! safeTxHash=${safeTxHash}`);
    console.log(`Nonce ${nonce} will be consumed by a 0-value self-transfer.`);
    console.log(`Go to safe.citrea.xyz to sign & execute.`);
  }
}

async function handleProposeUpgrade(config: Config, args: string[]) {
  const planPath = parseFlag(args, 'plan');
  let selectedPlan: string;

  if (planPath) {
    if (!fs.existsSync(planPath)) {
      throw new Error(`Plan file not found: ${planPath}`);
    }
    selectedPlan = planPath;
  } else {
    // Auto-detect from releases/{env}/
    const releasesDir = path.join('releases', config.env);
    if (!fs.existsSync(releasesDir)) {
      throw new Error(
        `No releases directory: ${releasesDir}. Run prepare-safe-upgrade first.`,
      );
    }

    const files = fs
      .readdirSync(releasesDir)
      .filter(
        (f) =>
          f.endsWith('safe-upgrade-plan.json') ||
          f.endsWith('safe-position-upgrade-plan.json'),
      );

    if (files.length === 0) {
      throw new Error(
        `No upgrade plan found in ${releasesDir}/. Run prepare-safe-upgrade first.`,
      );
    }

    files.sort();
    selectedPlan = path.join(releasesDir, files[files.length - 1]);

    if (files.length > 1) {
      console.log('Multiple plans found:');
      for (const f of files) {
        const marker = f === files[files.length - 1] ? ' <-- selected' : '';
        console.log(`  ${f}${marker}`);
      }
      console.log('Use --plan <path> for explicit selection.\n');
    }
  }

  // Read and validate plan
  const raw = fs.readFileSync(selectedPlan, 'utf8');
  const plan = JSON.parse(raw) as {
    network?: string;
    deployed?: Record<string, string>;
    safe?: { to?: string; value?: string; calldata?: string };
  };

  if (plan.network && plan.network !== config.env) {
    throw new Error(
      `Plan network "${plan.network}" does not match env "${config.env}"`,
    );
  }

  if (!plan.safe?.to || !plan.safe?.calldata) {
    throw new Error(`Plan missing safe.to or safe.calldata: ${selectedPlan}`);
  }

  console.log(`Plan: ${selectedPlan}`);
  if (plan.deployed) {
    console.log('Deployed:');
    for (const [name, addr] of Object.entries(plan.deployed)) {
      console.log(`  ${name}: ${addr}`);
    }
  }
  console.log(`Target: ${plan.safe.to}`);
  console.log(`Calldata: ${plan.safe.calldata.slice(0, 20)}...`);
  console.log();

  // Delegate to propose with parsed values
  const proposerKey = resolveProposerKey();
  const proposer = privateKeyToAccount(proposerKey as `0x${string}`);
  const protocolKit = await initProtocolKit(config, proposerKey);
  const apiKit = initApiKit(config);

  const transactions: TxInput[] = [
    {
      to: plan.safe.to,
      data: plan.safe.calldata,
      value: plan.safe.value || '0',
    },
  ];

  // Simulate
  if (!hasFlag(args, 'no-simulate')) {
    const client = createViemClient(config.env);
    console.log('Simulating upgrade...');
    const result = await simulateTx(
      client,
      config.safeAddress,
      transactions,
      false,
    );

    if (!result.success) {
      console.error(`\nSimulation FAILED: ${result.error}`);
      console.error('Upgrade NOT proposed.');
      process.exit(1);
    }
    console.log('Simulation passed.');
  } else {
    console.log('WARNING: simulation skipped (--no-simulate)');
  }

  // Propose
  console.log('Proposing upgrade...');
  const safeTxHash = await proposeTx(
    protocolKit,
    apiKit,
    transactions,
    config,
    proposer.address,
  );

  if (hasFlag(args, 'json')) {
    console.log(
      JSON.stringify({
        safeTxHash,
        safeAddress: config.safeAddress,
        plan: selectedPlan,
        env: config.env,
      }),
    );
  } else {
    console.log(`\nUpgrade proposed! safeTxHash=${safeTxHash}`);
    console.log(`Safe: ${config.safeAddress}`);
    console.log(`Go to safe.citrea.xyz to sign & execute.`);
  }
}

// ── Main ────────────────────────────────────────────────────

const COMMANDS = ['info', 'pending', 'propose', 'reject', 'propose-upgrade'];

async function main() {
  const args = process.argv.slice(2);
  const rawEnv = args[0];
  const command = args[1];

  if (!rawEnv || !command) {
    console.error(
      'Usage: tsx scripts/ops/safe.ts <env> <command> [flags]\n' +
        `Commands: ${COMMANDS.join(', ')}`,
    );
    process.exit(1);
  }

  if (rawEnv !== 'dev' && rawEnv !== 'prod') {
    console.error(`Only dev/prod supported (no TX Service for "${rawEnv}")`);
    process.exit(1);
  }

  if (!COMMANDS.includes(command)) {
    console.error(
      `Unknown command: ${command}\nCommands: ${COMMANDS.join(', ')}`,
    );
    process.exit(1);
  }

  const flags = args.slice(2);
  const config = resolveConfig(rawEnv, flags);

  switch (command) {
    case 'info':
      return handleInfo(config, flags);
    case 'pending':
      return handlePending(config, flags);
    case 'propose':
      return handlePropose(config, flags);
    case 'reject':
      return handleReject(config, flags);
    case 'propose-upgrade':
      return handleProposeUpgrade(config, flags);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
