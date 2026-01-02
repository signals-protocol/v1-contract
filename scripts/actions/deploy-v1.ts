import hre from "hardhat";
import { recordDeployment, updateConfig, updateContracts } from "../utils/environment";
import { buildReleaseMetaFromEnv, writeReleaseSnapshot } from "../utils/release";
import type { Environment } from "../types/environment";

export async function deployAction(env: Environment) {
  const { ethers, upgrades, network } = hre;
  console.log(`[deploy] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const submitWindow = BigInt(process.env.SETTLEMENT_SUBMIT_WINDOW ?? "600");
  const pendingOpsWindow = BigInt(process.env.SETTLEMENT_PENDING_OPS_WINDOW ?? "300");
  const finalizeDeadlineRaw = process.env.SETTLEMENT_FINALIZE_DEADLINE;
  const finalizeDeadline = finalizeDeadlineRaw
    ? BigInt(finalizeDeadlineRaw)
    : submitWindow + pendingOpsWindow;
  const defaultFeeBps = Number(process.env.DEFAULT_FEE_BPS ?? "0");
  const redstoneFeedIdRaw = process.env.REDSTONE_FEED_ID ?? "BTC";
  const redstoneFeedDecimals = Number(process.env.REDSTONE_FEED_DECIMALS ?? "8");
  const redstoneMaxSampleDistance = BigInt(process.env.REDSTONE_MAX_SAMPLE_DISTANCE ?? "600");
  const redstoneFutureTolerance = BigInt(process.env.REDSTONE_FUTURE_TOLERANCE ?? "60");
  const lpShareName = process.env.LP_SHARE_NAME ?? "Signals LP";
  const lpShareSymbol = process.env.LP_SHARE_SYMBOL ?? "SIGLP";

  if (!Number.isFinite(defaultFeeBps)) {
    throw new Error(`DEFAULT_FEE_BPS must be a number (got ${process.env.DEFAULT_FEE_BPS ?? "unset"})`);
  }
  if (!Number.isFinite(redstoneFeedDecimals)) {
    throw new Error(
      `REDSTONE_FEED_DECIMALS must be a number (got ${process.env.REDSTONE_FEED_DECIMALS ?? "unset"})`
    );
  }
  if (finalizeDeadline != submitWindow + pendingOpsWindow) {
    throw new Error(
      `SETTLEMENT_FINALIZE_DEADLINE must equal SETTLEMENT_SUBMIT_WINDOW + SETTLEMENT_PENDING_OPS_WINDOW ` +
        `(submit=${submitWindow}, ops=${pendingOpsWindow}, claim=${finalizeDeadline})`
    );
  }

  const paymentOverride =
    process.env.PAYMENT_TOKEN_ADDRESS || process.env.SIGNALS_USD_TOKEN_ADDRESS;
  let paymentAddress: string;
  if (paymentOverride) {
    paymentAddress = paymentOverride;
    console.log(`[deploy] using existing payment token=${paymentAddress}`);
  } else {
    const payment = await (await ethers.getContractFactory("SignalsUSDToken")).deploy();
    await payment.waitForDeployment();
    paymentAddress = payment.target.toString();
  }

  const feePolicy = await (await ethers.getContractFactory("MockFeePolicy")).deploy(defaultFeeBps);
  await feePolicy.waitForDeployment();

  const nullFeePolicy = await (await ethers.getContractFactory("NullFeePolicy")).deploy();
  await nullFeePolicy.waitForDeployment();

  const feePolicy10bps = await (await ethers.getContractFactory("PercentFeePolicy10bps")).deploy();
  await feePolicy10bps.waitForDeployment();

  const feePolicy50bps = await (await ethers.getContractFactory("PercentFeePolicy50bps")).deploy();
  await feePolicy50bps.waitForDeployment();

  const feePolicy100bps = await (await ethers.getContractFactory("PercentFeePolicy100bps")).deploy();
  await feePolicy100bps.waitForDeployment();

  const feePolicy200bps = await (await ethers.getContractFactory("PercentFeePolicy200bps")).deploy();
  await feePolicy200bps.waitForDeployment();

  const lazy = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
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

  const oracleModule = await (await ethers.getContractFactory("OracleModule")).deploy();
  await oracleModule.waitForDeployment();

  const riskModule = await (await ethers.getContractFactory("RiskModule")).deploy();
  await riskModule.waitForDeployment();

  const vaultModule = await (await ethers.getContractFactory("LPVaultModule")).deploy();
  await vaultModule.waitForDeployment();

  const positionFactory = await ethers.getContractFactory("SignalsPosition");
  const positionProxy = await upgrades.deployProxy(positionFactory, [deployer.address], { kind: "uups" });
  await positionProxy.waitForDeployment();
  const positionImpl = await upgrades.erc1967.getImplementationAddress(await positionProxy.getAddress());

  const coreFactory = await ethers.getContractFactory("SignalsCore");
  const coreProxy = await upgrades.deployProxy(
    coreFactory,
    [paymentAddress, positionProxy.target, submitWindow, finalizeDeadline],
    { kind: "uups", unsafeAllow: ["delegatecall"] }
  );
  await coreProxy.waitForDeployment();
  const coreImpl = await upgrades.erc1967.getImplementationAddress(await coreProxy.getAddress());
  const coreDeployTx = coreProxy.deploymentTransaction();
  if (coreDeployTx) {
    const receipt = await coreDeployTx.wait();
    if (receipt) {
      console.log(`[deploy] coreProxy block=${receipt.blockNumber} tx=${coreDeployTx.hash}`);
    }
  }

  const modulesTx = await coreProxy.setModules(
    tradeModule.target,
    lifecycleModule.target,
    riskModule.target,
    vaultModule.target,
    oracleModule.target
  );
  await modulesTx.wait();
  const setCoreTx = await positionProxy.setCore(coreProxy.target);
  await setCoreTx.wait();

  const lpShare = await (await ethers.getContractFactory("SignalsLPShare")).deploy(
    lpShareName,
    lpShareSymbol,
    coreProxy.target,
    paymentAddress
  );
  await lpShare.waitForDeployment();

  const setLpShareTx = await coreProxy.setLpShareToken(lpShare.target);
  await setLpShareTx.wait();

  const setTimelineTx = await coreProxy.setSettlementTimeline(
    submitWindow,
    pendingOpsWindow,
    finalizeDeadline
  );
  await setTimelineTx.wait();

  const redstoneFeedId = ethers.encodeBytes32String(redstoneFeedIdRaw);
  const redstoneTx = await coreProxy.setRedstoneConfig(
    redstoneFeedId,
    redstoneFeedDecimals,
    redstoneMaxSampleDistance,
    redstoneFutureTolerance
  );
  await redstoneTx.wait();

  updateContracts(env, {
    SignalsCoreProxy: coreProxy.target.toString(),
    SignalsCoreImplementation: coreImpl,
    SignalsPositionProxy: positionProxy.target.toString(),
    SignalsPositionImplementation: positionImpl,
    TradeModule: tradeModule.target.toString(),
    MarketLifecycleModule: lifecycleModule.target.toString(),
    OracleModule: oracleModule.target.toString(),
    RiskModule: riskModule.target.toString(),
    LPVaultModule: vaultModule.target.toString(),
    FeePolicy: feePolicy.target.toString(),
    FeePolicyNull: nullFeePolicy.target.toString(),
    FeePolicy10bps: feePolicy10bps.target.toString(),
    FeePolicy50bps: feePolicy50bps.target.toString(),
    FeePolicy100bps: feePolicy100bps.target.toString(),
    FeePolicy200bps: feePolicy200bps.target.toString(),
    SignalsUSDToken: paymentAddress,
    SignalsLPShare: lpShare.target.toString(),
    LazyMulSegmentTree: lazy.target.toString(),
  });

  updateConfig(env, {
    settlementSubmitWindow: submitWindow.toString(),
    settlementFinalizeDeadline: finalizeDeadline.toString(),
    pendingOpsWindow: pendingOpsWindow.toString(),
    defaultFeeBps,
    redstoneFeedId: redstoneFeedIdRaw,
    redstoneFeedDecimals,
    redstoneMaxSampleDistance: redstoneMaxSampleDistance.toString(),
    redstoneFutureTolerance: redstoneFutureTolerance.toString(),
    lpShareTokenName: lpShareName,
    lpShareTokenSymbol: lpShareSymbol,
    owners: {
      core: deployer.address,
      position: deployer.address,
    },
  });

  const releaseMeta = buildReleaseMetaFromEnv();
  const { data: envData, record } = recordDeployment(env, {
    action: "deploy",
    deployer: deployer.address,
    meta: releaseMeta,
  });
  writeReleaseSnapshot(env, envData, releaseMeta);

  console.log(`[deploy] completed (version=${record.version})`);
}
