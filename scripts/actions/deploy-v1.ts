import fs from "fs";
import path from "path";
import hre from "hardhat";
import {
  loadEnvironment,
  recordDeployment,
  updateConfig,
  updateContracts,
} from "../utils/environment";
import { writeReleaseSnapshot } from "../utils/release";
import type { Environment } from "../types/environment";
import { predictCreate2 } from "./predict-create2";

const CHAIN_ID_GUARD: Partial<Record<Environment, number>> = {
  testnet: 5115,
  prod: 4114,
};

const MANUAL_INPUTS = {
  ownerSafe: "0x0e5ed8B5Be63bf1f92Cc9A516B7cAADa1AeA6Bf8",
  paymentTokenAddress: "0x8D82c4E3c936C7B5724A382a9c5a4E6Eb7aB6d5D",
  operatorAllowlist: "0xe0785a8cDc92bAe49Ae7aA6C99B602e3CC43F7eD",
  settlement: {
    submitWindowSec: "600",
    pendingOpsWindowSec: "300",
  },
  redstone: {
    feedId: "BTC",
    feedDecimals: "8",
    maxSampleDistanceSec: "600",
    futureToleranceSec: "60",
  },
  risk: {
    lambda: "0.3",
    kDrawdown: "1",
    enforceAlpha: "0",
  },
  feeWaterfall: {
    rhoBS: "0.2",
    phiLP: "0.7",
    phiBS: "0.2",
    phiTR: "0.1",
  },
  withdrawalLagBatches: "0",
  lpShare: {
    name: "Signals LP",
    symbol: "SIGLP",
  },
  create2: {
    release: "v1",
    vanityPrefix: "0x516",
    maxNonce: "1000000",
  },
};

const INPUTS = MANUAL_INPUTS;

function parseAddressList(value: string): string[] {
  if (!value) return [];
  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function parseBigInt(value: string, label: string): bigint {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`${label} must be an integer (got ${value})`);
  }
}

function parseNumber(value: string, label: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${label} must be a number (got ${value})`);
  }
  return parsed;
}

function wad(value: string): bigint {
  return hre.ethers.parseUnits(value, 18);
}

function writePredicted(env: Environment, prediction: unknown) {
  const outputPath = path.join("scripts", "environments", `${env}.predicted.json`);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(prediction, null, 2));
  return outputPath;
}

export async function deployAction(env: Environment) {
  const { ethers, network } = hre;
  console.log(`[deploy] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const envData = loadEnvironment(env);

  const { chainId } = await ethers.provider.getNetwork();
  const expectedChainId = CHAIN_ID_GUARD[env];
  if (expectedChainId && Number(chainId) !== expectedChainId) {
    throw new Error(
      `ChainId mismatch: expected=${expectedChainId} got=${chainId}`
    );
  }

  const submitWindow = parseBigInt(
    INPUTS.settlement.submitWindowSec,
    "SETTLEMENT_SUBMIT_WINDOW"
  );
  const pendingOpsWindow = parseBigInt(
    INPUTS.settlement.pendingOpsWindowSec,
    "SETTLEMENT_PENDING_OPS_WINDOW"
  );
  const claimDelay = submitWindow + pendingOpsWindow;

  const redstoneFeedDecimals = parseNumber(
    INPUTS.redstone.feedDecimals,
    "REDSTONE_FEED_DECIMALS"
  );
  const redstoneMaxSampleDistance = parseBigInt(
    INPUTS.redstone.maxSampleDistanceSec,
    "REDSTONE_MAX_SAMPLE_DISTANCE"
  );
  const redstoneFutureTolerance = parseBigInt(
    INPUTS.redstone.futureToleranceSec,
    "REDSTONE_FUTURE_TOLERANCE"
  );

  const ownerSafe = INPUTS.ownerSafe || deployer.address;
  const operatorAllowlist = parseAddressList(INPUTS.operatorAllowlist);
  const resolvedOperators = operatorAllowlist.length
    ? operatorAllowlist
    : [deployer.address];

  const withdrawalLagBatches = parseNumber(
    INPUTS.withdrawalLagBatches,
    "WITHDRAWAL_LAG_BATCHES"
  );
  if (withdrawalLagBatches < 0) {
    throw new Error("WITHDRAWAL_LAG_BATCHES must be >= 0");
  }

  const riskLambda = wad(INPUTS.risk.lambda);
  const riskKDrawdown = wad(INPUTS.risk.kDrawdown);
  const riskEnforceAlpha =
    INPUTS.risk.enforceAlpha === "1" || INPUTS.risk.enforceAlpha === "true";
  const rhoBS = wad(INPUTS.feeWaterfall.rhoBS);
  const phiLP = wad(INPUTS.feeWaterfall.phiLP);
  const phiBS = wad(INPUTS.feeWaterfall.phiBS);
  const phiTR = wad(INPUTS.feeWaterfall.phiTR);

  let paymentAddress = INPUTS.paymentTokenAddress;
  if (env === "prod" && !paymentAddress) {
    throw new Error(
      "PAYMENT_TOKEN_ADDRESS is required for prod (no mock payment token deployment)"
    );
  }
  if (paymentAddress) {
    console.log(`[deploy] using existing payment token=${paymentAddress}`);
  } else {
    const payment = await (
      await ethers.getContractFactory("SignalsUSDToken")
    ).deploy();
    await payment.waitForDeployment();
    paymentAddress = payment.target.toString();
  }

  const decimalsContract = new ethers.Contract(
    paymentAddress,
    ["function decimals() view returns (uint8)"],
    deployer
  );
  const paymentDecimals = Number(await decimalsContract.decimals());
  if (paymentDecimals !== 6) {
    throw new Error(`paymentToken.decimals must be 6 (got ${paymentDecimals})`);
  }

  async function resolveImpl(label: string, contractName: string, existing?: string): Promise<string> {
    if (existing) {
      const code = await ethers.provider.getCode(existing);
      if (code !== "0x") {
        console.log(`[deploy] reusing ${label}=${existing}`);
        return existing;
      }
      console.warn(`[deploy] ${label} has no code at ${existing}; redeploying`);
    }

    const factory = await ethers.getContractFactory(contractName);
    const impl = await factory.deploy();
    await impl.waitForDeployment();
    return impl.target.toString();
  }

  const nullFeePolicy = await (
    await ethers.getContractFactory("NullFeePolicy")
  ).deploy();
  await nullFeePolicy.waitForDeployment();

  const feePolicy10bps = await (
    await ethers.getContractFactory("PercentFeePolicy10bps")
  ).deploy();
  await feePolicy10bps.waitForDeployment();

  const feePolicy50bps = await (
    await ethers.getContractFactory("PercentFeePolicy50bps")
  ).deploy();
  await feePolicy50bps.waitForDeployment();

  const feePolicy100bps = await (
    await ethers.getContractFactory("PercentFeePolicy100bps")
  ).deploy();
  await feePolicy100bps.waitForDeployment();

  const feePolicy200bps = await (
    await ethers.getContractFactory("PercentFeePolicy200bps")
  ).deploy();
  await feePolicy200bps.waitForDeployment();

  const lazy = await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy();
  await lazy.waitForDeployment();

  const tradeModule = await (
    await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazy.target },
    })
  ).deploy();
  await tradeModule.waitForDeployment();

  const lifecycleModule = await (
    await ethers.getContractFactory("MarketLifecycleModule", {
      libraries: { LazyMulSegmentTree: lazy.target },
    })
  ).deploy();
  await lifecycleModule.waitForDeployment();

  const oracleModule = await (
    await ethers.getContractFactory("OracleModule")
  ).deploy();
  await oracleModule.waitForDeployment();

  const riskModule = await (
    await ethers.getContractFactory("RiskModule")
  ).deploy();
  await riskModule.waitForDeployment();

  const vaultModule = await (
    await ethers.getContractFactory("LPVaultModule")
  ).deploy();
  await vaultModule.waitForDeployment();

  const coreImplAddress = await resolveImpl(
    "SignalsCoreImplementation",
    "SignalsCore",
    envData.contracts.SignalsCoreImplementation
  );
  const positionImplAddress = await resolveImpl(
    "SignalsPositionImplementation",
    "SignalsPosition",
    envData.contracts.SignalsPositionImplementation
  );
  const lpShareImplAddress = await resolveImpl(
    "SignalsLPShareImplementation",
    "SignalsLPShare",
    envData.contracts.SignalsLPShareImplementation
  );

  const create2FactoryAddress = await (async () => {
    const existing =
      envData.contracts.SignalsCreate2Factory ??
      envData.contracts.Create2Factory;
    if (existing) {
      const code = await ethers.provider.getCode(existing);
      if (code !== "0x") {
        return existing;
      }
      if (env === "prod") {
        throw new Error(`SignalsCreate2Factory has no code at ${existing}`);
      }
      console.warn(
        `[deploy] SignalsCreate2Factory not found at ${existing}; redeploying`
      );
    }
    const factory = await (
      await ethers.getContractFactory("SignalsCreate2Factory")
    ).deploy(deployer.address);
    await factory.waitForDeployment();
    return factory.target.toString();
  })();

  const factoryContract = await ethers.getContractAt(
    "SignalsCreate2Factory",
    create2FactoryAddress
  );
  const allowedDeployer = await factoryContract.allowedDeployer();
  if (allowedDeployer.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error(
      `SignalsCreate2Factory allowedDeployer mismatch: expected ${deployer.address} got ${allowedDeployer}`
    );
  }

  const prediction = await predictCreate2({
    env,
    chainId: Number(chainId),
    deployerEOA: deployer.address,
    create2Factory: create2FactoryAddress,
    coreImpl: coreImplAddress,
    positionImpl: positionImplAddress,
    lpShareImpl: lpShareImplAddress,
    release: INPUTS.create2.release,
    vanityPrefix: INPUTS.create2.vanityPrefix,
    maxNonce: parseNumber(INPUTS.create2.maxNonce, "CORE_VANITY_MAX_NONCE"),
  });

  const predictedPath = writePredicted(env, prediction);
  console.log(`[deploy] predicted addresses written to ${predictedPath}`);

  const deployerAddress = prediction.contracts.SignalsDeployer;
  const deployerFactory = await ethers.getContractFactory("SignalsDeployer");
  const deployerInitCode = ethers.concat([
    deployerFactory.bytecode,
    ethers.AbiCoder.defaultAbiCoder().encode(["address"], [deployer.address]),
  ]);

  const deployerCode = await ethers.provider.getCode(deployerAddress);
  if (deployerCode === "0x") {
    const deployTx = await factoryContract.deploy(
      prediction.create2.salts.DEPLOYER.salt,
      deployerInitCode
    );
    await deployTx.wait();
  }

  const deployerCodeAfter = await ethers.provider.getCode(deployerAddress);
  if (deployerCodeAfter === "0x") {
    throw new Error(`SignalsDeployer was not deployed at ${deployerAddress}`);
  }

  const coreParams = {
    paymentToken: paymentAddress,
    positionContract: prediction.contracts.SignalsPositionProxy,
    lpShareToken: prediction.contracts.SignalsLPShareProxy,
    tradeModule: tradeModule.target.toString(),
    lifecycleModule: lifecycleModule.target.toString(),
    riskModule: riskModule.target.toString(),
    vaultModule: vaultModule.target.toString(),
    oracleModule: oracleModule.target.toString(),
    ownerSafe,
    settlementSubmitWindow: submitWindow,
    pendingOpsWindow: pendingOpsWindow,
    claimDelaySeconds: claimDelay,
    redstoneFeedId: ethers.encodeBytes32String(INPUTS.redstone.feedId),
    redstoneFeedDecimals: redstoneFeedDecimals,
    maxSampleDistance: redstoneMaxSampleDistance,
    futureTolerance: redstoneFutureTolerance,
    lambda: riskLambda,
    kDrawdown: riskKDrawdown,
    enforceAlpha: riskEnforceAlpha,
    rhoBS,
    phiLP,
    phiBS,
    phiTR,
    withdrawalLagBatches,
    operatorAllowlist: resolvedOperators,
  };

  const deployerContract = await ethers.getContractAt(
    "SignalsDeployer",
    deployerAddress
  );
  const deployAllTx = await deployerContract.deployAllDeterministic(
    coreImplAddress,
    positionImplAddress,
    lpShareImplAddress,
    prediction.create2.salts.CORE_PROXY.salt,
    prediction.create2.salts.POSITION_PROXY.salt,
    prediction.create2.salts.LPSHARE_PROXY.salt,
    prediction.contracts.SignalsCoreProxy,
    prediction.contracts.SignalsPositionProxy,
    prediction.contracts.SignalsLPShareProxy,
    coreParams,
    INPUTS.lpShare.name,
    INPUTS.lpShare.symbol
  );
  const deployReceipt = await deployAllTx.wait();
  console.log(
    `[deploy] deployAllDeterministic tx=${deployAllTx.hash} block=${deployReceipt?.blockNumber}`
  );

  updateContracts(env, {
    SignalsCreate2Factory: create2FactoryAddress,
    SignalsDeployer: deployerAddress,
    SignalsCoreProxy: prediction.contracts.SignalsCoreProxy,
    SignalsCoreImplementation: coreImplAddress,
    SignalsPositionProxy: prediction.contracts.SignalsPositionProxy,
    SignalsPositionImplementation: positionImplAddress,
    SignalsLPShareProxy: prediction.contracts.SignalsLPShareProxy,
    SignalsLPShareImplementation: lpShareImplAddress,
    SignalsLPShare: prediction.contracts.SignalsLPShareProxy,
    TradeModule: tradeModule.target.toString(),
    MarketLifecycleModule: lifecycleModule.target.toString(),
    OracleModule: oracleModule.target.toString(),
    RiskModule: riskModule.target.toString(),
    LPVaultModule: vaultModule.target.toString(),
    FeePolicyNull: nullFeePolicy.target.toString(),
    FeePolicy10bps: feePolicy10bps.target.toString(),
    FeePolicy50bps: feePolicy50bps.target.toString(),
    FeePolicy100bps: feePolicy100bps.target.toString(),
    FeePolicy200bps: feePolicy200bps.target.toString(),
    PaymentToken: paymentAddress,
    LazyMulSegmentTree: lazy.target.toString(),
  });

  updateConfig(env, {
    settlementSubmitWindow: submitWindow.toString(),
    settlementFinalizeDeadline: claimDelay.toString(),
    pendingOpsWindow: pendingOpsWindow.toString(),
    redstoneFeedId: INPUTS.redstone.feedId,
    redstoneFeedDecimals,
    redstoneMaxSampleDistance: redstoneMaxSampleDistance.toString(),
    redstoneFutureTolerance: redstoneFutureTolerance.toString(),
    lpShareTokenName: INPUTS.lpShare.name,
    lpShareTokenSymbol: INPUTS.lpShare.symbol,
    operatorAllowlist: resolvedOperators,
    owners: {
      core: ownerSafe,
      position: ownerSafe,
      lpShare: ownerSafe,
    },
    deployerEOA: deployer.address,
  });

  const { data: envSnapshot, record } = recordDeployment(env, {
    action: "deploy",
    deployer: deployer.address,
  });
  writeReleaseSnapshot(env, envSnapshot);

  console.log(`[deploy] completed (version=${record.version})`);
}
