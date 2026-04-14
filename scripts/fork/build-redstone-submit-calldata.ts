import { Contract, providers, utils } from 'ethers';
import { WrapperBuilder } from '@redstone-finance/evm-connector';
import {
  getSignersForDataServiceId,
  type DataServiceIds,
} from '@redstone-finance/sdk';
import { loadEnvironment, normalizeEnvironment } from '../utils/environment';
import type { Environment, EnvironmentFile } from '../types/environment';

const BUILD_PREFIX = '[build-redstone-submit-calldata]';
const REDSTONE_DATA_SERVICE_ID: DataServiceIds = 'redstone-primary-prod';
const REDSTONE_UNIQUE_SIGNERS = 3;
const CORE_ABI = [
  'function submitSettlementSample(uint256)',
  'function redstoneFeedId() view returns (bytes32)',
  'function maxSampleDistance() view returns (uint64)',
] as const;

type WrappedSubmitContract = Contract & {
  populateTransaction: {
    submitSettlementSample(marketId: string): Promise<{ data?: string }>;
  };
};

function log(message: string) {
  console.error(`${BUILD_PREFIX} ${message}`);
}

function fail(message: string): never {
  throw new Error(message);
}

function resolveRpcUrl(env: Environment): string {
  const envVar =
    env === 'dev'
      ? 'DEV_RPC_URL'
      : env === 'prod'
        ? 'PROD_RPC_URL'
        : 'LOCAL_RPC_URL';
  const value = process.env[envVar];
  if (!value) {
    fail(`Missing ${envVar}`);
  }
  return value;
}

function resolveCoreAddress(
  passedCoreAddress: string | undefined,
  envData: EnvironmentFile,
): string {
  if (passedCoreAddress) {
    return passedCoreAddress;
  }
  const fromEnvFile = envData.contracts.SignalsCoreProxy;
  if (!fromEnvFile) {
    fail('Missing SignalsCoreProxy in environment file');
  }
  return fromEnvFile;
}

function resolveFeedIdFallback(envData: EnvironmentFile): string {
  const configuredFeedId = envData.config?.redstoneFeedId;
  if (!configuredFeedId) {
    fail('Missing redstoneFeedId in environment file');
  }
  return configuredFeedId;
}

async function resolveFeedId(
  contract: Contract,
  envData: EnvironmentFile,
): Promise<string> {
  try {
    const onchainFeedId = (await contract.redstoneFeedId()) as string;
    return utils.parseBytes32String(onchainFeedId);
  } catch {
    return resolveFeedIdFallback(envData);
  }
}

async function resolveMaxTimestampDeviationMs(
  contract: Contract,
  envData: EnvironmentFile,
): Promise<number | undefined> {
  try {
    const onchainMaxDistance = (await contract.maxSampleDistance()) as {
      toNumber(): number;
    };
    return onchainMaxDistance.toNumber() * 1000;
  } catch {
    const configured = envData.config?.redstoneMaxSampleDistance;
    if (!configured) return undefined;
    const parsed = Number(configured);
    return Number.isFinite(parsed) ? parsed * 1000 : undefined;
  }
}

async function main() {
  const [envArg, coreAddressArg, marketIdArg] = process.argv.slice(2);
  if (!envArg || !marketIdArg) {
    fail(
      'Usage: tsx scripts/fork/build-redstone-submit-calldata.ts <env> <core-address> <market-id>',
    );
  }
  if (!/^\d+$/.test(marketIdArg)) {
    fail(`Invalid market ID: ${marketIdArg}`);
  }

  const env = normalizeEnvironment(envArg) as Environment;
  const envData = loadEnvironment(env);
  const coreAddress = resolveCoreAddress(coreAddressArg, envData);
  const provider = new providers.JsonRpcProvider(resolveRpcUrl(env));
  const core = new Contract(coreAddress, CORE_ABI, provider);

  const feedId = await resolveFeedId(core, envData);
  const maxTimestampDeviationMS = await resolveMaxTimestampDeviationMs(
    core,
    envData,
  );

  const wrapped = WrapperBuilder.wrap(core).usingDataService({
    dataServiceId: REDSTONE_DATA_SERVICE_ID,
    dataPackagesIds: [feedId],
    uniqueSignersCount: REDSTONE_UNIQUE_SIGNERS,
    authorizedSigners: getSignersForDataServiceId(REDSTONE_DATA_SERVICE_ID),
    ...(maxTimestampDeviationMS ? { maxTimestampDeviationMS } : {}),
  }) as WrappedSubmitContract;

  const tx =
    await wrapped.populateTransaction.submitSettlementSample(marketIdArg);
  if (!tx.data || !tx.data.startsWith('0x')) {
    fail('Failed to build calldata');
  }

  process.stdout.write(`${tx.data}\n`);
}

main().catch((error: unknown) => {
  const message =
    error instanceof Error ? error.message : 'Unknown error building calldata';
  log(message);
  process.exit(1);
});
