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
} from "../../../typechain-types";
import { ISignalsCore } from "../../../typechain-types/contracts/harness/TradeModuleProxy";
import { WAD } from "../../helpers/constants";

interface DeployedSystem {
  owner: HardhatEthersSigner;
  user: HardhatEthersSigner;
  payment: MockPaymentToken;
  position: SignalsPosition;
  core: TradeModuleProxy;
  feePolicy: MockFeePolicy;
}

describe("TradeModule flow (minimal parity)", () => {
  async function deploySystem(
    marketOverrides: Partial<ISignalsCore.MarketStruct> = {},
    feeBps = 0
  ): Promise<DeployedSystem> {
    const [owner, user] = await ethers.getSigners();

    const payment = await (
      await ethers.getContractFactory("MockPaymentToken")
    ).deploy();
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
    ).deploy(positionImpl.target, positionInit)) as TestERC1967Proxy;
    const position = (await ethers.getContractAt(
      "SignalsPosition",
      await positionProxy.getAddress()
    )) as SignalsPosition;
    const feePolicy = await (
      await ethers.getContractFactory("MockFeePolicy")
    ).deploy(feeBps);

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
      1,
      1,
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
      ...marketOverrides,
    };
    await core.setMarket(1, market);
    await core.seedTree(1, [WAD, WAD, WAD, WAD]);

    await position.connect(owner).setCore(core.target);

    // fund user
    await payment.transfer(user.address, 10_000_000n); // 10 USDC (6 decimals)
    await payment.connect(user).approve(core.target, ethers.MaxUint256);

    return {
      owner,
      user,
      payment: payment as MockPaymentToken,
      position: position as SignalsPosition,
      core: core as TradeModuleProxy,
      feePolicy: feePolicy as MockFeePolicy,
    };
  }

  it("open -> increase -> decrease -> close updates balances and openPositionCount", async () => {
    const { user, payment, core, position } = await deploySystem();

    const startBal = await payment.balanceOf(user.address);

    const nextId = await position.nextId();
    const positionId = Number(nextId);
    await core.connect(user).openPosition(1, 0, 4, 1_000, 5_000_000); // 0.001 USDC

    let market = await core.markets(1);
    expect(market.openPositionCount).to.equal(1);

    await core.connect(user).increasePosition(positionId, 1_000, 5_000_000);
    await core.connect(user).decreasePosition(positionId, 1_000, 0);
    await core.connect(user).closePosition(positionId, 0);

    market = await core.markets(1);
    expect(market.openPositionCount).to.equal(0);
    expect(await position.exists(positionId)).to.equal(false);

    const endBal = await payment.balanceOf(user.address);
    expect(endBal).to.be.lessThan(startBal); // paid trading cost overall
  });

  it("rejects zero quantity and misaligned ticks", async () => {
    const { user, core } = await deploySystem();
    await expect(core.connect(user).openPosition(1, 0, 4, 0, 1_000_000)).to.be
      .reverted;

    const { user: u2, core: c2 } = await deploySystem({ tickSpacing: 2 });
    await expect(c2.connect(u2).openPosition(1, 1, 3, 1_000, 5_000_000)).to.be
      .reverted;
  });

  it("reverts on inactive market and invalid ticks", async () => {
    const { user, core } = await deploySystem({ isActive: false });
    await expect(core.connect(user).openPosition(1, 0, 4, 1_000, 5_000_000)).to
      .be.reverted;

    const { user: user2, core: core2 } = await deploySystem();
    await expect(core2.connect(user2).openPosition(1, 0, 5, 1_000, 5_000_000))
      .to.be.reverted;
  });

  it("calculateOpenCost matches actual debit (fee=0)", async () => {
    const { user, core, payment } = await deploySystem();
    const quote = await core.calculateOpenCost.staticCall(1, 0, 4, 1_000);
    const balBefore = await payment.balanceOf(user.address);
    await core.connect(user).openPosition(1, 0, 4, 1_000, quote);
    const balAfter = await payment.balanceOf(user.address);
    expect(balBefore - balAfter).to.equal(quote);
  });

  it("allows claim after settlement and burns position", async () => {
    const { user, core, payment, position } = await deploySystem();
    const quote = await core.calculateOpenCost.staticCall(1, 0, 4, 1_000);
    await core.connect(user).openPosition(1, 0, 4, 1_000, quote);

    // mark market settled in the past to satisfy claim gate
    // Phase 6: settlementFinalizedAt must be set to past time for claim to be allowed
    const m = await core.markets(1);
    const past = m.endTimestamp - 1000n;
    const settledMarket: ISignalsCore.MarketStruct = {
      isActive: m.isActive,
      settled: true,
      snapshotChunksDone: m.snapshotChunksDone,
      failed: m.failed,
      numBins: m.numBins,
      openPositionCount: m.openPositionCount,
      snapshotChunkCursor: m.snapshotChunkCursor,
      startTimestamp: m.startTimestamp,
      endTimestamp: past,
      settlementTimestamp: past,
      settlementFinalizedAt: past, // Phase 6: Set to past so claim gating passes
      minTick: m.minTick,
      maxTick: m.maxTick,
      tickSpacing: m.tickSpacing,
      settlementTick: 2n, // Winning tick within position range [0,4)
      settlementValue: m.settlementValue,
      liquidityParameter: m.liquidityParameter,
      feePolicy: m.feePolicy,
      initialRootSum: m.initialRootSum,
      accumulatedFees: m.accumulatedFees,
      minFactor: m.minFactor, // Phase 7
    };
    await core.setMarket(1, settledMarket);

    // Note: This test uses TradeModuleProxy which doesn't have harness functions
    // Payout may be 0 since exposure ledger and payout reserve are not set
    // The key assertion is that claimPayout succeeds and burns the position
    const balBefore = await payment.balanceOf(user.address);
    await core.connect(user).claimPayout(1);
    const balAfter = await payment.balanceOf(user.address);
    // Balance may stay the same if payout is 0 (no exposure set)
    expect(balAfter).to.be.gte(balBefore);
    expect(await position.exists(1)).to.equal(false);
  });

  it("reverts claim when market not settled or too early, and disallows double-claim", async () => {
    const { user, core } = await deploySystem();
    const quote = await core.calculateOpenCost.staticCall(1, 0, 4, 1_000);
    await core.connect(user).openPosition(1, 0, 4, 1_000, quote);

    // not settled yet
    await expect(core.connect(user).claimPayout(1)).to.be.reverted;

    // settle but too early for claim window
    // Phase 6: Claim gating is time-based (settlementFinalizedAt + Δ_claim)
    const currentTime = BigInt(await ethers.provider.getBlock("latest").then(b => b!.timestamp));
    const m = await core.markets(1);
    const earlySettleMarket: ISignalsCore.MarketStruct = {
      isActive: m.isActive,
      settled: true,
      snapshotChunksDone: m.snapshotChunksDone,
      failed: m.failed,
      numBins: m.numBins,
      openPositionCount: m.openPositionCount,
      snapshotChunkCursor: m.snapshotChunkCursor,
      startTimestamp: m.startTimestamp,
      endTimestamp: m.endTimestamp,
      settlementTimestamp: currentTime,
      settlementFinalizedAt: currentTime + 3600n, // Future: claim window not open yet
      minTick: m.minTick,
      maxTick: m.maxTick,
      tickSpacing: m.tickSpacing,
      settlementTick: m.settlementTick,
      settlementValue: m.settlementValue,
      liquidityParameter: m.liquidityParameter,
      feePolicy: m.feePolicy,
      initialRootSum: m.initialRootSum,
      accumulatedFees: m.accumulatedFees,
      minFactor: m.minFactor, // Phase 7
    };
    await core.setMarket(1, earlySettleMarket);
    await expect(core.connect(user).claimPayout(1)).to.be.reverted;

    // allow claim by moving settlementFinalizedAt to past
    // Phase 6: claim gating is time-based (settlementFinalizedAt + Δ_claim)
    const m2 = await core.markets(1);
    const pastTime = m2.endTimestamp - 1000n;
    const claimableMarket: ISignalsCore.MarketStruct = {
      isActive: m2.isActive,
      settled: m2.settled,
      snapshotChunksDone: m2.snapshotChunksDone,
      failed: m2.failed,
      numBins: m2.numBins,
      openPositionCount: m2.openPositionCount,
      snapshotChunkCursor: m2.snapshotChunkCursor,
      startTimestamp: m2.startTimestamp,
      endTimestamp: m2.endTimestamp,
      settlementTimestamp: pastTime,
      settlementFinalizedAt: pastTime, // Phase 6: Must be in past for claim to succeed
      minTick: m2.minTick,
      maxTick: m2.maxTick,
      tickSpacing: m2.tickSpacing,
      settlementTick: m2.settlementTick,
      settlementValue: m2.settlementValue,
      liquidityParameter: m2.liquidityParameter,
      feePolicy: m2.feePolicy,
      initialRootSum: m2.initialRootSum,
      accumulatedFees: m2.accumulatedFees,
      minFactor: m2.minFactor, // Phase 7
    };
    await core.setMarket(1, claimableMarket);
    await core.connect(user).claimPayout(1);
    await expect(core.connect(user).claimPayout(1)).to.be.reverted; // burned position
  });

  it("enforces maxCost and minProceeds, and applies fee policy", async () => {
    const system = await deploySystem({}, 100); // 1% fee
    const { user, core, payment, feePolicy } = system;
    const tradeModule = (await ethers.getContractAt(
      "TradeModule",
      await core.module()
    )) as unknown as TradeModule;
    const m = await core.markets(1);
    const feeMarket: ISignalsCore.MarketStruct = {
      isActive: m.isActive,
      settled: m.settled,
      snapshotChunksDone: m.snapshotChunksDone,
      failed: m.failed,
      numBins: m.numBins,
      openPositionCount: m.openPositionCount,
      snapshotChunkCursor: m.snapshotChunkCursor,
      startTimestamp: m.startTimestamp,
      endTimestamp: m.endTimestamp,
      settlementTimestamp: m.settlementTimestamp,
      settlementFinalizedAt: m.settlementFinalizedAt,
      minTick: m.minTick,
      maxTick: m.maxTick,
      tickSpacing: m.tickSpacing,
      settlementTick: m.settlementTick,
      settlementValue: m.settlementValue,
      liquidityParameter: m.liquidityParameter,
      feePolicy: await feePolicy.getAddress(),
      initialRootSum: m.initialRootSum,
      accumulatedFees: m.accumulatedFees,
      minFactor: m.minFactor, // Phase 7
    };
    await core.setMarket(1, feeMarket);
    await expect(
      core.connect(user).openPosition(1, 0, 4, 1_000, 1)
    ).to.be.revertedWithCustomError(tradeModule, "CostExceedsMaximum");

    const quote = await core.calculateOpenCost.staticCall(1, 0, 4, 1_000);
    await core.connect(user).openPosition(1, 0, 4, 1_000, quote + 10_000n);

    await expect(
      core.connect(user).decreasePosition(1, 500, quote)
    ).to.be.revertedWithCustomError(tradeModule, "ProceedsBelowMinimum");

    // Phase 6 (WP v1.0): Fee NOT transferred to feeRecipient during trade
    // Fee accumulates in core for Waterfall distribution after settlement
    const feeRecipient = await core.feeRecipient();
    const feeBefore = await payment.balanceOf(feeRecipient);
    await core.connect(user).closePosition(1, 0);
    const feeAfter = await payment.balanceOf(feeRecipient);
    // Fee should NOT change - fee stays in core
    expect(feeAfter).to.equal(feeBefore);
  });

  it("reverts when allowance is insufficient", async () => {
    const { user, payment, core } = await deploySystem();
    await payment.connect(user).approve(core.target, 0);
    await expect(core.connect(user).openPosition(1, 0, 4, 1_000, 5_000_000)).to
      .be.reverted;
  });
});
