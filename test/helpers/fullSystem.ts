import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MockFeePolicy,
  SignalsUSDToken,
  LPVaultModule,
  MarketLifecycleModule,
  OracleModuleHarness,
  RiskModule,
  SignalsCore,
  SignalsLPShare,
  SignalsPosition,
  TradeModule,
} from "../../typechain-types";
import { DATA_FEED_ID, FEED_DECIMALS } from "./redstone";
import { WAD } from "./constants";

export interface FullSystem {
  owner: HardhatEthersSigner;
  users: HardhatEthersSigner[];
  payment: SignalsUSDToken;
  feePolicy: MockFeePolicy;
  core: SignalsCore;
  position: SignalsPosition;
  tradeModule: TradeModule;
  lifecycleModule: MarketLifecycleModule;
  oracleModule: OracleModuleHarness;
  riskModule: RiskModule;
  vaultModule: LPVaultModule;
  lpShare: SignalsLPShare;
  lazyLibrary: string;
}

export interface DeployFullSystemOptions {
  submitWindow?: number;
  opsWindow?: number;
  claimDelay?: number;
}

export async function deployFullSystem(
  options: DeployFullSystemOptions = {}
): Promise<FullSystem> {
  const submitWindow = options.submitWindow ?? 5;
  const opsWindow = options.opsWindow ?? 5;
  const expectedClaimDelay = submitWindow + opsWindow;
  const claimDelay = options.claimDelay ?? expectedClaimDelay;
  if (claimDelay !== expectedClaimDelay) {
    throw new Error(
      `claimDelay must equal submitWindow + opsWindow (expected ${expectedClaimDelay}, got ${claimDelay})`
    );
  }

  const signers = await ethers.getSigners();
  const owner = signers[0];
  const users = signers.slice(1, 6);

  const payment = (await (
    await ethers.getContractFactory("SignalsUSDToken")
  ).deploy()) as SignalsUSDToken;

  const feePolicy = (await (
    await ethers.getContractFactory("MockFeePolicy")
  ).deploy(0)) as MockFeePolicy;

  const lazyLib = await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy();

  const tradeModule = (await (
    await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    })
  ).deploy()) as TradeModule;

  const lifecycleModule = (await (
    await ethers.getContractFactory("MarketLifecycleModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    })
  ).deploy()) as MarketLifecycleModule;

  const oracleModule = (await (
    await ethers.getContractFactory("OracleModuleHarness")
  ).deploy()) as OracleModuleHarness;

  const riskModule = (await (
    await ethers.getContractFactory("RiskModule")
  ).deploy()) as RiskModule;

  const vaultModule = (await (
    await ethers.getContractFactory("LPVaultModule")
  ).deploy()) as LPVaultModule;

  const positionImplFactory = await ethers.getContractFactory("SignalsPosition");
  const positionImpl = await positionImplFactory.deploy();
  await positionImpl.waitForDeployment();

  const lpShareImplFactory = await ethers.getContractFactory("SignalsLPShare");
  const lpShareImpl = await lpShareImplFactory.deploy();
  await lpShareImpl.waitForDeployment();

  const coreImplFactory = await ethers.getContractFactory("SignalsCore");
  const coreImpl = await coreImplFactory.deploy();
  await coreImpl.waitForDeployment();

  const proxyFactory = await ethers.getContractFactory("TestERC1967Proxy");
  const positionProxy = await proxyFactory.deploy(positionImpl.target, "0x");
  const lpShareProxy = await proxyFactory.deploy(lpShareImpl.target, "0x");
  const coreProxy = await proxyFactory.deploy(coreImpl.target, "0x");

  const position = (await ethers.getContractAt(
    "SignalsPosition",
    await positionProxy.getAddress()
  )) as SignalsPosition;
  const lpShare = (await ethers.getContractAt(
    "SignalsLPShare",
    await lpShareProxy.getAddress()
  )) as SignalsLPShare;
  const core = (await ethers.getContractAt(
    "SignalsCore",
    await coreProxy.getAddress()
  )) as SignalsCore;

  const feedId = ethers.encodeBytes32String(DATA_FEED_ID);
  const coreParams: SignalsCore.InitParamsStruct = {
    paymentToken: payment.target.toString(),
    positionContract: await position.getAddress(),
    lpShareToken: await lpShare.getAddress(),
    tradeModule: tradeModule.target.toString(),
    lifecycleModule: lifecycleModule.target.toString(),
    riskModule: riskModule.target.toString(),
    vaultModule: vaultModule.target.toString(),
    oracleModule: oracleModule.target.toString(),
    ownerSafe: owner.address,
    settlementSubmitWindow: submitWindow,
    pendingOpsWindow: opsWindow,
    claimDelaySeconds: claimDelay,
    redstoneFeedId: feedId,
    redstoneFeedDecimals: FEED_DECIMALS,
    maxSampleDistance: 600,
    futureTolerance: 60,
    lambda: WAD / 10n,
    kDrawdown: WAD,
    enforceAlpha: true,
    rhoBS: 0,
    phiLP: WAD,
    phiBS: 0,
    phiTR: 0,
    withdrawalLagBatches: 1,
    operatorAllowlist: [owner.address],
  };
  await core.initialize(coreParams);
  await position.initialize(await core.getAddress(), owner.address);
  await lpShare.initialize(
    await core.getAddress(),
    payment.target.toString(),
    "Signals LP",
    "SIGLP",
    owner.address
  );

  return {
    owner,
    users,
    payment,
    feePolicy,
    core,
    position,
    tradeModule,
    lifecycleModule,
    oracleModule,
    riskModule,
    vaultModule,
    lpShare,
    lazyLibrary: lazyLib.target.toString(),
  };
}
