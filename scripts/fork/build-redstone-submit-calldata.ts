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
  'function getMarket(uint256) view returns (tuple(bool isSeeded,bool settled,bool snapshotChunksDone,bool failed,uint32 numBins,uint32 openPositionCount,uint32 snapshotChunkCursor,uint32 seedCursor,uint64 startTimestamp,uint64 endTimestamp,uint64 settlementTimestamp,uint64 settlementFinalizedAt,int256 minTick,int256 maxTick,int256 tickSpacing,int256 settlementTick,int256 settlementValue,uint256 liquidityParameter,address feePolicy,address seedData,uint256 initialRootSum,uint256 accumulatedFees,uint256 minFactor,uint256 deltaEt,bytes32 feedId,uint8 feedDecimals,uint64 tickScale))',
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

async function resolveFeedId(
  contract: Contract,
  marketId: string,
): Promise<string> {
  const market = (await contract.getMarket(marketId)) as {
    feedId?: string;
    [index: number]: unknown;
  };
  const feedId = market.feedId ?? market[24];
  if (typeof feedId !== 'string') {
    fail(`Market ${marketId} has no feedId`);
  }
  return utils.parseBytes32String(feedId);
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

  const feedId = await resolveFeedId(core, marketIdArg);
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
