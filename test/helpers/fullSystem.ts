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
  const positionInit = positionImplFactory.interface.encodeFunctionData(
    "initialize",
    [owner.address]
  );
  const positionProxy = await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(positionImpl.target, positionInit);
  const position = (await ethers.getContractAt(
    "SignalsPosition",
    await positionProxy.getAddress()
  )) as SignalsPosition;

  const coreImplFactory = await ethers.getContractFactory("SignalsCore");
  const coreImpl = await coreImplFactory.deploy();
  await coreImpl.waitForDeployment();
  const coreInit = coreImplFactory.interface.encodeFunctionData("initialize", [
    payment.target,
    await position.getAddress(),
    submitWindow,
    claimDelay,
  ]);
  const coreProxy = await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(coreImpl.target, coreInit);
  const core = (await ethers.getContractAt(
    "SignalsCore",
    await coreProxy.getAddress()
  )) as SignalsCore;

  await core.setModules(
    tradeModule.target,
    lifecycleModule.target,
    riskModule.target,
    vaultModule.target,
    oracleModule.target
  );
  await core.setSettlementTimeline(submitWindow, opsWindow, claimDelay);

  const feedId = ethers.encodeBytes32String(DATA_FEED_ID);
  await core.setRedstoneConfig(feedId, FEED_DECIMALS, 600, 60);

  await position.connect(owner).setCore(await core.getAddress());

  const lpShare = (await (
    await ethers.getContractFactory("SignalsLPShare")
  ).deploy(
    "Signals LP",
    "SIGLP",
    await core.getAddress(),
    payment.target
  )) as SignalsLPShare;
  await core.setLpShareToken(lpShare.target);

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
