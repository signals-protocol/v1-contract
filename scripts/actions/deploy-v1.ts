import hre from "hardhat";
import { appendHistory, loadEnvironment, updateContracts } from "../utils/environment";
import type { Environment } from "../types/environment";

export async function deployAction(env: Environment) {
  const { ethers, upgrades, network } = hre;
  console.log(`[deploy] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const submitWindow = BigInt(process.env.SETTLEMENT_SUBMIT_WINDOW ?? "600");
  const finalizeDeadline = BigInt(process.env.SETTLEMENT_FINALIZE_DEADLINE ?? "3600");
  const defaultFeeBps = Number(process.env.DEFAULT_FEE_BPS ?? "0");

  const payment = await (await ethers.getContractFactory("MockPaymentToken")).deploy();
  await payment.waitForDeployment();

  const feePolicy = await (await ethers.getContractFactory("MockFeePolicy")).deploy(defaultFeeBps);
  await feePolicy.waitForDeployment();

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

  const positionFactory = await ethers.getContractFactory("SignalsPosition");
  const positionProxy = await upgrades.deployProxy(positionFactory, [deployer.address], { kind: "uups" });
  await positionProxy.waitForDeployment();
  const positionImpl = await upgrades.erc1967.getImplementationAddress(positionProxy.target);

  const coreFactory = await ethers.getContractFactory("SignalsCore");
  const coreProxy = await upgrades.deployProxy(
    coreFactory,
    [payment.target, positionProxy.target, submitWindow, finalizeDeadline],
    { kind: "uups" }
  );
  await coreProxy.waitForDeployment();
  const coreImpl = await upgrades.erc1967.getImplementationAddress(coreProxy.target);

  await coreProxy.setModules(
    tradeModule.target,
    lifecycleModule.target,
    ethers.ZeroAddress,
    ethers.ZeroAddress,
    oracleModule.target
  );
  await coreProxy.setOracleConfig(deployer.address);
  await positionProxy.setCore(coreProxy.target);

  updateContracts(env, {
    SignalsCoreProxy: coreProxy.target.toString(),
    SignalsCoreImplementation: coreImpl,
    SignalsPositionProxy: positionProxy.target.toString(),
    SignalsPositionImplementation: positionImpl,
    TradeModule: tradeModule.target.toString(),
    MarketLifecycleModule: lifecycleModule.target.toString(),
    OracleModule: oracleModule.target.toString(),
    FeePolicy: feePolicy.target.toString(),
    PaymentToken: payment.target.toString(),
    LazyMulSegmentTree: lazy.target.toString(),
  });

  const now = Math.floor(Date.now() / 1000);
  const envData = loadEnvironment(env);
  appendHistory(env, {
    version: envData.version + 1,
    action: "deploy",
    deployer: deployer.address,
    timestamp: now,
  });

  console.log("[deploy] completed");
}
