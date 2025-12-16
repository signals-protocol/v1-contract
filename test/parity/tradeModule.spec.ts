import { ethers } from "hardhat";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MockPaymentToken,
  MockFeePolicy,
  TradeModuleProxy,
  TradeModule,
  SignalsPosition,
  TestERC1967Proxy,
} from "../../typechain-types";
import { ISignalsCore } from "../../typechain-types/contracts/harness/TradeModuleProxy";
import { WAD } from "../helpers/constants";

interface DeployedSystem {
  owner: HardhatEthersSigner;
  userA: HardhatEthersSigner;
  userB: HardhatEthersSigner;
  payment: MockPaymentToken;
  position: SignalsPosition;
  core: TradeModuleProxy;
  feePolicy: MockFeePolicy;
  tradeModule: TradeModule;
}

async function deploySystem(
  marketOverrides: Partial<ISignalsCore.MarketStruct> = {},
  feeBps = 0
): Promise<DeployedSystem> {
  const [owner, userA, userB] = await ethers.getSigners();

  const payment = await (
    await ethers.getContractFactory("MockPaymentToken")
  ).deploy();
  const feePolicy = await (
    await ethers.getContractFactory("MockFeePolicy")
  ).deploy(feeBps);

  const positionImplFactory = await ethers.getContractFactory(
    "SignalsPosition"
  );
  const positionImpl = await positionImplFactory.deploy();
  await positionImpl.waitForDeployment();
  const positionInit = positionImplFactory.interface.encodeFunctionData(
    "initialize",
    [owner.address]
  );
  const positionProxy = (await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(await positionImpl.getAddress(), positionInit)) as TestERC1967Proxy;
  const position = (await ethers.getContractAt(
    "SignalsPosition",
    await positionProxy.getAddress()
  )) as SignalsPosition;

  const lazyLib = await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy();
  const tradeModule = await (
    await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    })
  ).deploy();
  const core = await (
    await ethers.getContractFactory("TradeModuleProxy", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    })
  ).deploy(tradeModule.target);

  await core.setAddresses(
    payment.target,
    await position.getAddress(),
    300,
    60,
    owner.address,
    feePolicy.target
  );

  const now = (await ethers.provider.getBlock("latest"))!.timestamp;
  const market: ISignalsCore.MarketStruct = {
    isActive: true,
    settled: false,
    snapshotChunksDone: false,
    failed: false,
    numBins: 4,
    openPositionCount: 0,
    snapshotChunkCursor: 0,
    startTimestamp: now - 10,
    endTimestamp: now + 1000,
    settlementTimestamp: now + 1100,
    settlementFinalizedAt: 0,
    minTick: 0,
    maxTick: 4,
    tickSpacing: 1,
    settlementTick: 0,
    settlementValue: 0,
    liquidityParameter: WAD,
    feePolicy: ethers.ZeroAddress,
    initialRootSum: 4n * WAD,
    accumulatedFees: 0n,
    minFactor: WAD, // Phase 7: uniform prior
      deltaEt: 0n, // Uniform prior: ΔEₜ = 0
    ...marketOverrides,
  };
  await core.setMarket(1, market);
  await core.seedTree(1, [WAD, WAD, WAD, WAD]);
  await position.connect(owner).setCore(core.target);

  // fund users
  await payment.transfer(userA.address, 10_000_000n);
  await payment.transfer(userB.address, 10_000_000n);
  await payment.connect(userA).approve(core.target, ethers.MaxUint256);
  await payment.connect(userB).approve(core.target, ethers.MaxUint256);

  return {
    owner,
    userA,
    userB,
    payment,
    position,
    core: core as TradeModuleProxy,
    feePolicy: feePolicy as MockFeePolicy,
    tradeModule: tradeModule as TradeModule,
  };
}

describe("TradeModule parity and multi-user flows", () => {
  it("matches decrease proceeds with view quote", async () => {
    const { userA, payment, position, core } = await deploySystem();

    const nextId = await position.nextId();
    const positionId = Number(nextId);
    await core.connect(userA).openPosition(1, 0, 4, 2_000, 10_000_000); // 0.002 USDC

    const quote = await core.calculateDecreaseProceeds.staticCall(
      positionId,
      800
    );
    const balBefore = await payment.balanceOf(userA.address);
    await core.connect(userA).decreasePosition(positionId, 800, quote);
    const balAfter = await payment.balanceOf(userA.address);
    expect(balAfter - balBefore).to.equal(quote);

    const pos = await position.getPosition(positionId);
    expect(pos.quantity).to.equal(1_200);
  });

  it("handles multi-user slippage and partial close", async () => {
    const { userA, userB, payment, position, core, tradeModule } =
      await deploySystem();

    const posAId = Number(await position.nextId());
    await core.connect(userA).openPosition(1, 0, 4, 1_500, 10_000_000);

    const quoteB = await core.calculateOpenCost.staticCall(1, 0, 4, 1_000);
    await expect(
      core.connect(userB).openPosition(1, 0, 4, 1_000, quoteB - 1n)
    ).to.be.revertedWithCustomError(tradeModule, "CostExceedsMaximum");
    const posBId = posAId + 1;
    await core.connect(userB).openPosition(1, 0, 4, 1_000, quoteB + 1_000n);

    const decQuote = await core.calculateDecreaseProceeds.staticCall(
      posBId,
      600
    );
    const balBBefore = await payment.balanceOf(userB.address);
    await core.connect(userB).decreasePosition(posBId, 600, decQuote);
    const balBAfter = await payment.balanceOf(userB.address);
    expect(balBAfter - balBBefore).to.equal(decQuote);

    await core.connect(userB).closePosition(posBId, 0);
    expect(await position.exists(posBId)).to.equal(false);
    // A still open; close and ensure counts drop
    await core.connect(userA).closePosition(posAId, 0);
    const market = await core.markets(1);
    expect(market.openPositionCount).to.equal(0);
  });
});
