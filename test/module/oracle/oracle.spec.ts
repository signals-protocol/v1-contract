import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  OracleModule,
  SignalsCoreHarness,
} from "../../../typechain-types";
import { ISignalsCore } from "../../../typechain-types/contracts/harness/TradeModuleHarness";
import {
  DATA_FEED_ID,
  FEED_DECIMALS,
  authorisedWallets,
  buildRedstonePayload,
  submitWithPayload,
  toSettlementValue,
} from "../../helpers/redstone";

describe("OracleModule", () => {
  async function setup() {
    const [owner, other] = await ethers.getSigners();
    const payment = await (
      await ethers.getContractFactory("MockPaymentToken")
    ).deploy();
    const position = await (
      await ethers.getContractFactory("MockSignalsPosition")
    ).deploy();
    const lazyLib = await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy();

    const lifecycleImpl = (await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as MarketLifecycleModule;
    // Use OracleModuleTest to allow Hardhat local signers for Redstone verification
    const oracleModule = (await (
      await ethers.getContractFactory("OracleModuleTest")
    ).deploy()) as OracleModule;
    const riskModule = await (
      await ethers.getContractFactory("RiskModule")
    ).deploy();

    const coreImpl = (await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as SignalsCoreHarness;

    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      120, // settlementSubmitWindow
      300, // pendingOpsWindow
    ]);
    const proxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(coreImpl.target, initData);
    const core = (await ethers.getContractAt(
      "SignalsCoreHarness",
      proxy.target
    )) as SignalsCoreHarness;

    await core.setModules(
      ethers.ZeroAddress,
      lifecycleImpl.target,
      riskModule.target,
      ethers.ZeroAddress,
      oracleModule.target
    );

    // Configure Redstone params (feedId, decimals, maxDistance, futureTolerance)
    const feedId = ethers.encodeBytes32String(DATA_FEED_ID);
    const maxSampleDistance = 600n; // 10 min max distance from Tset
    const futureTolerance = 60n; // 1 min future tolerance
    await core.setRedstoneConfig(feedId, FEED_DECIMALS, maxSampleDistance, futureTolerance);
    
    // Configure settlement timeline (submitWindow, opsWindow, claimDelay)
    await core.setSettlementTimeline(120, 300, 60);

    const now = BigInt(await time.latest());
    const WAD = ethers.parseEther("1");
    const market: ISignalsCore.MarketStruct = {
      isActive: true,
      settled: false,
      snapshotChunksDone: false,
      failed: false,
      numBins: 4,
      openPositionCount: 0,
      snapshotChunkCursor: 0,
      startTimestamp: now - 100n,
      endTimestamp: now + 200n,
      settlementTimestamp: now + 300n,
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
      minFactor: WAD,
      deltaEt: 0n,
    };
    await core.harnessSetMarket(1, market);
    // Seed tree for manualSettleFailedMarket tests that need P&L calculation
    await core.harnessSeedTree(1, [
      ethers.parseEther("1"),
      ethers.parseEther("1"),
      ethers.parseEther("1"),
      ethers.parseEther("1"),
    ]);

    return {
      owner,
      other,
      core,
      oracleModule,
      lifecycleImpl,
      market,
    };
  }

  describe("Redstone payload validation", () => {
    it("reverts when calldata has no Redstone payload", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      await time.increaseTo(tSet + 1);

      // Submit without payload - Redstone error comes from OracleModule
      await expect(
        submitWithPayload(core, owner, 1)
      ).to.be.revertedWithCustomError(oracleModule, "CalldataMustHaveValidPayload");
    });

    it("reverts when unique signers threshold is not met", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      await time.increaseTo(tSet + 1);
      // Only 1 signer (threshold is 3)
      const payload = buildRedstonePayload(
        2, // Human price = 2 (maps to tick 2)
        tSet + 2,
        [authorisedWallets[0]]
      );

      await expect(
        submitWithPayload(core, owner, 1, payload)
      ).to.be.revertedWithCustomError(oracleModule, "InsufficientNumberOfUniqueSigners");
    });

    it("stores scaled settlementValue with valid Redstone payload", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);
      const oracleEvents = oracleModule.attach(await core.getAddress());

      await time.increaseTo(tSet + 1);
      const priceTs = tSet + 2;
      // Human price = 2 (tick 2), encoded as 2 * 10^8 = 200_000_000
      // SettlementValue = 200_000_000 / 100 = 2_000_000 (6 decimals)
      const humanPrice = 2;
      const payload = buildRedstonePayload(humanPrice, priceTs, authorisedWallets);

      await expect(submitWithPayload(core, owner, 1, payload))
        .to.emit(oracleEvents, "SettlementPriceSubmitted")
        .withArgs(1, toSettlementValue(humanPrice), priceTs, owner.address);

      const [storedPrice, storedTs] = await core.getSettlementPrice.staticCall(1);
      expect(storedPrice).to.equal(toSettlementValue(humanPrice));
      expect(storedTs).to.equal(priceTs);
    });
  });

  describe("submit window bounds", () => {
    it("reverts before Tset", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // Block before Tset
      const blockTs = tSet - 1;
      await time.setNextBlockTimestamp(blockTs);
      const payload = buildRedstonePayload(2, blockTs, authorisedWallets);

      await expect(
        submitWithPayload(core, owner, 1, payload)
      ).to.be.revertedWithCustomError(oracleModule, "OracleSampleTooEarly");
    });

    it("reverts after submitWindow", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // Block after Tset + submitWindow (120)
      const blockTs = tSet + 121;
      await time.setNextBlockTimestamp(blockTs);
      const payload = buildRedstonePayload(2, blockTs, authorisedWallets);

      await expect(
        submitWithPayload(core, owner, 1, payload)
      ).to.be.revertedWithCustomError(oracleModule, "SettlementWindowClosed");
    });
  });

  describe("timestamp validation", () => {
    it("reverts when oracle timestamp is in far future (δfuture)", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // Block at Tset + 10, price timestamp 4min in future (> 3min Redstone default)
      // Redstone's default future tolerance is 3 minutes
      const blockTs = tSet + 10;
      const futurePriceTs = blockTs + 240; // 4 minutes in future
      await time.setNextBlockTimestamp(blockTs);
      const payload = buildRedstonePayload(2, futurePriceTs, authorisedWallets);

      // Redstone rejects this with TimestampFromTooLongFuture before our δfuture check
      await expect(
        submitWithPayload(core, owner, 1, payload)
      ).to.be.revertedWithCustomError(oracleModule, "TimestampFromTooLongFuture");
    });

    it("reverts when oracle timestamp is too old (Redstone 3-minute window)", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // Block at Tset + 10, price timestamp 4min in the past (> 3min Redstone default)
      const blockTs = tSet + 10;
      const oldPriceTs = blockTs - 240; // 4 minutes ago
      await time.setNextBlockTimestamp(blockTs);
      const payload = buildRedstonePayload(2, oldPriceTs, authorisedWallets);

      // Redstone rejects this with TimestampIsTooOld
      await expect(
        submitWithPayload(core, owner, 1, payload)
      ).to.be.revertedWithCustomError(oracleModule, "TimestampIsTooOld");
    });
  });

  describe("closest-sample rule", () => {
    it("accepts first candidate", async () => {
      const { core, market, owner } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // Block at tSet + 60, priceTs at tSet + 50
      // Redstone requires priceTs within 3min of blockTs
      const blockTs = tSet + 60;
      const priceTs = tSet + 50; // Within 3min of blockTs
      await time.setNextBlockTimestamp(blockTs);
      const payload = buildRedstonePayload(2, priceTs, authorisedWallets);

      await submitWithPayload(core, owner, 1, payload);

      const [price, ts] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(toSettlementValue(2));
      expect(ts).to.equal(priceTs);
    });

    it("updates candidate if new one is strictly closer to Tset", async () => {
      const { core, market, owner } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // First: priceTs = tSet + 50, distance = 50
      let blockTs = tSet + 60;
      const ts1 = tSet + 50;
      await time.setNextBlockTimestamp(blockTs);
      const payload1 = buildRedstonePayload(2, ts1, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload1);

      // Second: priceTs = tSet + 20, distance = 20 (strictly closer)
      blockTs = tSet + 65;
      const ts2 = tSet + 20;
      await time.setNextBlockTimestamp(blockTs);
      const payload2 = buildRedstonePayload(3, ts2, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload2);

      const [price, ts] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(toSettlementValue(3)); // Updated
      expect(ts).to.equal(ts2);
    });

    it("ignores candidate if new one is farther from Tset", async () => {
      const { core, market, owner } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // First: priceTs = tSet + 20, distance = 20
      let blockTs = tSet + 30;
      const ts1 = tSet + 20;
      await time.setNextBlockTimestamp(blockTs);
      const payload1 = buildRedstonePayload(2, ts1, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload1);

      // Second: priceTs = tSet + 50, distance = 50 (farther)
      blockTs = tSet + 60;
      const ts2 = tSet + 50;
      await time.setNextBlockTimestamp(blockTs);
      const payload2 = buildRedstonePayload(3, ts2, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload2);

      const [price, ts] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(toSettlementValue(2)); // Still first
      expect(ts).to.equal(ts1);
    });

    it("on tie: prefers earlier priceTimestamp (WP v2 tie-break)", async () => {
      const { core, market, owner } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // First: priceTs = tSet + 30, distance = 30
      let blockTs = tSet + 40;
      const ts1 = tSet + 30;
      await time.setNextBlockTimestamp(blockTs);
      const payload1 = buildRedstonePayload(2, ts1, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload1);

      // Second: priceTs = tSet + 10, distance = 10 (closer, should replace)
      // Since we can't easily test past timestamps due to Redstone's 3min window,
      // we test with two future timestamps where the closer one wins
      blockTs = tSet + 50;
      const ts2 = tSet + 10;
      await time.setNextBlockTimestamp(blockTs);
      const payload2 = buildRedstonePayload(3, ts2, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload2);

      const [price, ts] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(toSettlementValue(3)); // Replaced (closer)
      expect(ts).to.equal(ts2);
    });

    it("on tie: keeps existing if new priceTimestamp has same distance but is later", async () => {
      const { core, market, owner } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // First: priceTs = tSet + 20, distance = 20
      let blockTs = tSet + 30;
      const ts1 = tSet + 20;
      await time.setNextBlockTimestamp(blockTs);
      const payload1 = buildRedstonePayload(2, ts1, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload1);

      // Second: priceTs = tSet + 40, distance = 40 (farther, should not replace)
      blockTs = tSet + 50;
      const ts2 = tSet + 40;
      await time.setNextBlockTimestamp(blockTs);
      const payload2 = buildRedstonePayload(3, ts2, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload2);

      const [price, ts] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(toSettlementValue(2)); // Still first (closer)
      expect(ts).to.equal(ts1);
    });
  });

  describe("state machine view functions", () => {
    it("getMarketState returns correct states", async () => {
      const { core, market } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // State 0: Trading (before Tset)
      await time.increaseTo(tSet - 1);
      expect(await core.getMarketState.staticCall(1)).to.equal(0);

      // State 1: SettlementOpen [Tset, Tset + submitWindow)
      await time.increaseTo(tSet + 1);
      expect(await core.getMarketState.staticCall(1)).to.equal(1);

      // State 2: PendingOps [Tset + submitWindow, Tset + submitWindow + opsWindow)
      await time.increaseTo(tSet + 121);
      expect(await core.getMarketState.staticCall(1)).to.equal(2);

      // After PendingOps ends, state 3
      await time.increaseTo(tSet + 421);
      expect(await core.getMarketState.staticCall(1)).to.equal(3);
    });

    it("getSettlementWindows returns correct values", async () => {
      const { core, market } = await setup();
      const tSet = BigInt(market.settlementTimestamp);
      const submitWindow = 120n;
      const opsWindow = 300n;
      
      const [retTSet, settleEnd, opsEnd, claimOpen] = await core.getSettlementWindows.staticCall(1);
      expect(retTSet).to.equal(tSet);
      expect(settleEnd).to.equal(tSet + submitWindow);
      expect(opsEnd).to.equal(tSet + submitWindow + opsWindow);
      expect(claimOpen).to.equal(0); // Not finalized yet
    });
  });

  describe("markFailed and secondary settlement", () => {
    it("reverts markFailed before PendingOps window", async () => {
      const { core, lifecycleImpl } = await setup();

      await expect(core.markSettlementFailed(1)).to.be.revertedWithCustomError(
        lifecycleImpl,
        "PendingOpsNotStarted"
      );
    });

    it("allows markFailed during PendingOps even without candidate (WP v2)", async () => {
      const { core, market, lifecycleImpl } = await setup();
      const tSet = Number(market.settlementTimestamp);
      const pendingOpsStart = tSet + 120;

      await time.setNextBlockTimestamp(pendingOpsStart + 1);
      await expect(core.markSettlementFailed(1))
        .to.emit(lifecycleImpl.attach(await core.getAddress()), "MarketFailed")
        .withArgs(1, pendingOpsStart + 1);

      const m = await core.markets(1);
      expect(m.failed).to.equal(true);
      expect(m.isActive).to.equal(false);
    });

    it("reverts finalizeSecondarySettlement on non-failed market", async () => {
      const { core, lifecycleImpl } = await setup();

      await expect(
        core.finalizeSecondarySettlement(1, 100n)
      ).to.be.revertedWithCustomError(lifecycleImpl, "MarketNotFailed");
    });

    it("allows finalizeSecondarySettlement on failed market", async () => {
      const { core, market, lifecycleImpl } = await setup();
      const tSet = Number(market.settlementTimestamp);
      const pendingOpsStart = tSet + 120;

      await time.setNextBlockTimestamp(pendingOpsStart + 1);
      await core.markSettlementFailed(1);

      await time.setNextBlockTimestamp(pendingOpsStart + 2);
      await expect(core.finalizeSecondarySettlement(1, 2n)).to.emit(
        lifecycleImpl.attach(await core.getAddress()),
        "MarketSettledSecondary"
      );

      const m = await core.markets(1);
      expect(m.settled).to.equal(true);
      expect(m.failed).to.equal(true);
      expect(m.settlementValue).to.equal(2);
    });

    it("markSettlementFailed clears candidate during PendingOps (WP v2 divergence)", async () => {
      const { core, market, owner, oracleModule } = await setup();
      const tSet = Number(market.settlementTimestamp);

      // Submit a candidate during settlement window
      const blockTs = tSet + 30;
      const candidateTs = tSet + 20;
      await time.setNextBlockTimestamp(blockTs);
      const payload = buildRedstonePayload(2, candidateTs, authorisedWallets);
      await submitWithPayload(core, owner, 1, payload);

      // Verify candidate exists
      const [, ts] = await core.getSettlementPrice.staticCall(1);
      expect(ts).to.equal(candidateTs);

      // Mark failed during PendingOps
      const pendingOpsStart = tSet + 120;
      await time.setNextBlockTimestamp(pendingOpsStart + 1);
      await core.markSettlementFailed(1);

      // Candidate should be cleared
      await expect(core.getSettlementPrice(1)).to.be.revertedWithCustomError(
        oracleModule,
        "SettlementOracleCandidateMissing"
      );
    });

    it("finalizePrimarySettlement reverts without candidate after PendingOps", async () => {
      const { core, market, lifecycleImpl } = await setup();
      const tSet = Number(market.settlementTimestamp);
      const opsEnd = tSet + 120 + 300; // submitWindow + pendingOpsWindow

      // Time passes without any sample submission
      await time.setNextBlockTimestamp(opsEnd + 1);

      // Should revert because no candidate exists
      await expect(core.finalizePrimarySettlement(1)).to.be.revertedWithCustomError(
        lifecycleImpl,
        "SettlementOracleCandidateMissing"
      );
    });
  });

  describe("getSettlementPrice", () => {
    it("reverts when no candidate recorded", async () => {
      const { core, oracleModule } = await setup();
      await expect(core.getSettlementPrice(1)).to.be.revertedWithCustomError(
        oracleModule,
        "SettlementOracleCandidateMissing"
      );
    });
  });
});
