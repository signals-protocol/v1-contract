import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  OracleModule,
  SignalsCoreHarness,
} from "../../../typechain-types";
import { ISignalsCore } from "../../../typechain-types/contracts/testonly/TradeModuleHarness";
import {
  DATA_FEED_ID,
  FEED_DECIMALS,
  authorisedWallets,
  buildRedstonePayload,
  submitWithPayload,
  toSettlementValue,
} from "../../helpers/redstone";

const WAD = ethers.parseEther("1");

function cloneMarket(
  market: ISignalsCore.MarketStruct,
  overrides: Partial<ISignalsCore.MarketStruct> = {}
): ISignalsCore.MarketStruct {
  return {
    isActive: market.isActive,
    settled: market.settled,
    snapshotChunksDone: market.snapshotChunksDone,
    failed: market.failed,
    numBins: market.numBins,
    openPositionCount: market.openPositionCount,
    snapshotChunkCursor: market.snapshotChunkCursor,
    startTimestamp: market.startTimestamp,
    endTimestamp: market.endTimestamp,
    settlementTimestamp: market.settlementTimestamp,
    settlementFinalizedAt: market.settlementFinalizedAt,
    minTick: market.minTick,
    maxTick: market.maxTick,
    tickSpacing: market.tickSpacing,
    settlementTick: market.settlementTick,
    settlementValue: market.settlementValue,
    liquidityParameter: market.liquidityParameter,
    feePolicy: market.feePolicy,
    initialRootSum: market.initialRootSum,
    accumulatedFees: market.accumulatedFees,
    minFactor: market.minFactor ?? WAD,
    deltaEt: market.deltaEt ?? 0n,
    ...overrides,
  };
}

// Redstone feed config (for setRedstoneConfig)
const FEED_ID = ethers.encodeBytes32String(DATA_FEED_ID);
const MAX_SAMPLE_DISTANCE = 600n; // 10 min
const FUTURE_TOLERANCE = 60n; // 1 min

// Human price value (maps to tick 2 with proper market config)
// Redstone encodes as 2 * 10^8 = 200_000_000
// On-chain extraction: 200_000_000
// SettlementValue = 200_000_000 / 100 = 2_000_000 (6 decimals)
const HUMAN_PRICE = 2;

describe("MarketLifecycleModule", () => {
  async function setup() {
    const [owner] = await ethers.getSigners();
    const payment = await (
      await ethers.getContractFactory("SignalsUSDToken")
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
    // Use OracleModuleHarness to allow Hardhat local signers for Redstone verification
    const oracleModule = (await (
      await ethers.getContractFactory("OracleModuleHarness")
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
      60, // pendingOpsWindow
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
    
    // Configure Redstone oracle params
    await core.setRedstoneConfig(FEED_ID, FEED_DECIMALS, MAX_SAMPLE_DISTANCE, FUTURE_TOLERANCE);

    return {
      owner,
      core,
      lifecycle: lifecycleImpl,
      oracleModule,
      lazyLib,
    };
  }

  async function createDefaultMarket(core: SignalsCoreHarness) {
    const now = BigInt(await time.latest());
    const start = now - 100n;
    const end = now + 200n;
    await core.createMarketUniform(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(end),
      4,
      ethers.parseEther("1"),
      ethers.ZeroAddress
    );
    return { start, end };
  }

  it("creates market with seeded tree and validated params", async () => {
    const { core, lifecycle } = await setup();
    const now = BigInt(await time.latest());
    const start = now + 10n;
    const end = start + 100n;
    const settlementTs = end + 50n;

    const lifecycleEvents = lifecycle.attach(await core.getAddress());

    const marketId = await core.createMarketUniform.staticCall(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(settlementTs),
      4,
      ethers.parseEther("1"),
      ethers.ZeroAddress
    );
    const tx = await core.createMarketUniform(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(settlementTs),
      4,
      ethers.parseEther("1"),
      ethers.ZeroAddress
    );
    await expect(tx).to.emit(lifecycleEvents, "MarketCreated");
    const expectedFactors = [WAD, WAD, WAD, WAD];
    await expect(tx)
      .to.emit(lifecycleEvents, "MarketFactorsSeeded")
      .withArgs(marketId, expectedFactors);

    const market = await core.markets(marketId);
    expect(market.isActive).to.equal(true);
    expect(market.numBins).to.equal(4);
    expect(market.liquidityParameter).to.equal(ethers.parseEther("1"));
    expect(await core.harnessGetTreeSize(marketId)).to.equal(4);
    expect(await core.harnessGetTreeSum(marketId)).to.equal(4n * 10n ** 18n);
  });

  it("rejects invalid market parameters and time ranges", async () => {
    const { core, lifecycle } = await setup();
    await expect(
      core.createMarketUniform(
        0,
        0,
        1,
        0,
        1,
        1,
        1,
        ethers.parseEther("1"),
        ethers.ZeroAddress
      )
    ).to.be.revertedWithCustomError(lifecycle, "InvalidMarketParameters");

    await expect(
      core.createMarketUniform(
        0,
        4,
        0,
        0,
        1,
        1,
        1,
        ethers.parseEther("1"),
        ethers.ZeroAddress
      )
    ).to.be.revertedWithCustomError(lifecycle, "InvalidMarketParameters");

    await expect(
      core.createMarketUniform(
        0,
        4,
        1,
        10,
        5,
        5,
        4,
        ethers.parseEther("1"),
        ethers.ZeroAddress
      )
    ).to.be.revertedWithCustomError(lifecycle, "InvalidTimeRange");

    await expect(
      core.createMarketUniform(
        0,
        4,
        1,
        0,
        10,
        5,
        4,
        ethers.parseEther("1"),
        ethers.ZeroAddress
      )
    ).to.be.revertedWithCustomError(lifecycle, "InvalidTimeRange");

    await expect(
      core.createMarketUniform(0, 4, 1, 0, 10, 10, 4, 0, ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(lifecycle, "InvalidLiquidityParameter");
  });

  it("settles market when candidate exists and marks snapshot state", async () => {
    const { core, lifecycle, oracleModule } = await setup();
    const { end } = await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());

    // Submit oracle candidate during settlement window
    const candidateTs = end + 10n;
    await time.setNextBlockTimestamp(Number(candidateTs + 1n));
    const payload = buildRedstonePayload(HUMAN_PRICE, Number(candidateTs), authorisedWallets);
    await submitWithPayload(core, (await ethers.getSigners())[0], 1, payload);

    // Set open positions to keep snapshotChunksDone false
    const marketBefore = await core.markets(1);
    await core.harnessSetMarket(
      1,
      cloneMarket(marketBefore, { openPositionCount: 10 })
    );

    // Finalize after PendingOps ends (submitWindow=120, pendingOpsWindow=60)
    // tSet = end for this market
    const tSet = end;
    const opsEnd = tSet + 120n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await expect(core.finalizePrimarySettlement(1)).to.emit(
      lifecycleEvents,
      "MarketSettled"
    );

    const market = await core.markets(1);
    expect(market.settled).to.equal(true);
    expect(market.settlementValue).to.equal(toSettlementValue(HUMAN_PRICE));
    expect(market.snapshotChunkCursor).to.equal(0);
    expect(market.snapshotChunksDone).to.equal(false);

    // Candidate should be cleared after settlement
    await expect(core.getSettlementPrice(1)).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementOracleCandidateMissing"
    );
  });

  it("finalizePrimary enforces candidate and window checks", async () => {
    const { core, lifecycle, oracleModule } = await setup();
    const { end } = await createDefaultMarket(core);
    const tSet = end; // settlementTimestamp = endTimestamp
    const opsEnd = tSet + 120n + 60n; // submitWindow + pendingOpsWindow

    const owner = (await ethers.getSigners())[0];
    
    // Test 1: Submit before Tset: should revert
    const earlyBlockTs = tSet - 1n;
    await time.setNextBlockTimestamp(Number(earlyBlockTs));
    const earlyPayload = buildRedstonePayload(HUMAN_PRICE, Number(earlyBlockTs), authorisedWallets);
    await expect(
      submitWithPayload(core, owner, 1, earlyPayload)
    ).to.be.revertedWithCustomError(oracleModule, "OracleSampleTooEarly");

    // Test 2: Valid candidate submission within window
    const goodTs = tSet + 10n;
    await time.setNextBlockTimestamp(Number(goodTs + 1n));
    const goodPayload = buildRedstonePayload(HUMAN_PRICE, Number(goodTs), authorisedWallets);
    await submitWithPayload(core, owner, 1, goodPayload);
    
    // Test 3: Finalize before opsEnd: should revert with PendingOpsNotStarted
    await time.setNextBlockTimestamp(Number(goodTs + 10n));
    await expect(core.finalizePrimarySettlement(1)).to.be.revertedWithCustomError(
      lifecycle,
      "PendingOpsNotStarted"
    );

    // Test 4: Submit after window: should revert
    const lateBlockTs = tSet + 121n; // submitWindow = 120
    await time.setNextBlockTimestamp(Number(lateBlockTs));
    const latePayload = buildRedstonePayload(HUMAN_PRICE, Number(lateBlockTs), authorisedWallets);
    await expect(
      submitWithPayload(core, owner, 1, latePayload)
    ).to.be.revertedWithCustomError(oracleModule, "SettlementWindowClosed");
    
    // Test 5: Finalize after opsEnd: should succeed
    await time.setNextBlockTimestamp(Number(opsEnd + 2n));
    await expect(core.finalizePrimarySettlement(1)).to.emit(lifecycle.attach(await core.getAddress()), "MarketSettled");
  });

  it("reopens settled market and resets state", async () => {
    const { core } = await setup();
    await createDefaultMarket(core);
    const market = await core.markets(1);
    await core.harnessSetMarket(
      1,
      cloneMarket(market, {
        settled: true,
        settlementValue: 5,
        settlementTick: 2,
        settlementTimestamp: market.settlementTimestamp + 10n,
        snapshotChunksDone: true,
        snapshotChunkCursor: 1,
      })
    );

    await core.reopenMarket(1);
    const reopened = await core.markets(1);
    expect(reopened.settled).to.equal(false);
    expect(reopened.isActive).to.equal(true);
    expect(reopened.settlementValue).to.equal(0);
    expect(reopened.snapshotChunkCursor).to.equal(0);
    expect(reopened.snapshotChunksDone).to.equal(false);
  });

  it("marks settlement failed during PendingOps window when no candidate", async () => {
    const { core, lifecycle } = await setup();
    const { end } = await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());
    const tSet = end;
    const opsStart = tSet + 120n; // settlementSubmitWindow

    // Move to PendingOps window (no candidate submitted)
    await time.setNextBlockTimestamp(Number(opsStart + 1n));
    
    await expect(core.markSettlementFailed(1))
      .to.emit(lifecycleEvents, "MarketFailed")
      .withArgs(1, opsStart + 1n);

    const market = await core.markets(1);
    expect(market.failed).to.equal(true);
    expect(market.isActive).to.equal(false);
    expect(market.settled).to.equal(false);
  });

  it("rejects markSettlementFailed before PendingOps starts", async () => {
    const { core, lifecycle } = await setup();
    const { end } = await createDefaultMarket(core);
    const tSet = end;

    // Before PendingOps
    await time.setNextBlockTimestamp(Number(tSet + 10n));
    await expect(core.markSettlementFailed(1))
      .to.be.revertedWithCustomError(lifecycle, "PendingOpsNotStarted");
  });

  it("rejects markSettlementFailed after PendingOps if candidate exists", async () => {
    const { core, oracleModule } = await setup();
    const { end } = await createDefaultMarket(core);
    const tSet = end;
    const opsEnd = tSet + 120n + 60n;

    // Submit candidate
    const candidateTs = tSet + 10n;
    await time.setNextBlockTimestamp(Number(candidateTs + 1n));
    const payload = buildRedstonePayload(HUMAN_PRICE, Number(candidateTs), authorisedWallets);
    await submitWithPayload(core, (await ethers.getSigners())[0], 1, payload);

    // After PendingOps with candidate - should use finalize instead
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await expect(core.markSettlementFailed(1))
      .to.be.revertedWithCustomError(oracleModule, "SettlementOracleCandidateMissing");
  });

  it("finalizes secondary settlement for failed market", async () => {
    const { core, lifecycle } = await setup();
    const { end } = await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());
    const tSet = end;
    const opsStart = tSet + 120n;

    // Mark as failed first
    await time.setNextBlockTimestamp(Number(opsStart + 1n));
    await core.markSettlementFailed(1);

    // Finalize secondary settlement with ops-provided value
    const settlementValue = 2_000_000n; // 2.0 in 6 decimals
    await expect(core.finalizeSecondarySettlement(1, settlementValue))
      .to.emit(lifecycleEvents, "MarketSettledSecondary");

    const market = await core.markets(1);
    expect(market.settled).to.equal(true);
    expect(market.failed).to.equal(true);
    expect(market.settlementValue).to.equal(settlementValue);
  });

  it("rejects finalizeSecondarySettlement for non-failed market", async () => {
    const { core, lifecycle } = await setup();
    await createDefaultMarket(core);

    await expect(core.finalizeSecondarySettlement(1, 1_000_000n))
      .to.be.revertedWithCustomError(lifecycle, "MarketNotFailed");
  });

  it("rejects finalizeSecondarySettlement for already settled market", async () => {
    const { core, lifecycle } = await setup();
    const { end } = await createDefaultMarket(core);
    const tSet = end;
    const opsStart = tSet + 120n;

    // Mark as failed
    await time.setNextBlockTimestamp(Number(opsStart + 1n));
    await core.markSettlementFailed(1);

    // First secondary settlement
    await core.finalizeSecondarySettlement(1, 2_000_000n);

    // Second attempt should fail
    await expect(core.finalizeSecondarySettlement(1, 1_000_000n))
      .to.be.revertedWithCustomError(lifecycle, "MarketAlreadySettled");
  });

  it("updates market timing and activation", async () => {
    const { core, lifecycle } = await setup();
    await createDefaultMarket(core);

    await core.setMarketActive(1, false);
    let market = await core.markets(1);
    expect(market.isActive).to.equal(false);
    await core.setMarketActive(1, true);
    market = await core.markets(1);
    expect(market.isActive).to.equal(true);

    await expect(core.setMarketActive(1, true)).not.to.be.reverted;

    await expect(
      core.updateMarketTiming(1, 10, 5, 5)
    ).to.be.revertedWithCustomError(lifecycle, "InvalidTimeRange");

    await core.updateMarketTiming(1, 5, 10, 15);
    market = await core.markets(1);
    expect(market.startTimestamp).to.equal(5);
    expect(market.endTimestamp).to.equal(10);
    expect(market.settlementTimestamp).to.equal(15);
  });

  it("emits settlement chunk requests and marks completion", async () => {
    const { core, lifecycle } = await setup();
    await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());

    const market = await core.markets(1);
    await core.harnessSetMarket(
      1,
      cloneMarket(market, { settled: true, openPositionCount: 1000 })
    );

    const tx1 = await core.requestSettlementChunks(1, 1);
    await expect(tx1)
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(1, 0);
    let updated = await core.markets(1);
    expect(updated.snapshotChunkCursor).to.equal(1);
    expect(updated.snapshotChunksDone).to.equal(false);

    const tx2 = await core.requestSettlementChunks(1, 5);
    await expect(tx2)
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(1, 1);
    updated = await core.markets(1);
    expect(updated.snapshotChunkCursor).to.equal(2); // ceil(1000/512)
    expect(updated.snapshotChunksDone).to.equal(true);

    await expect(
      core.requestSettlementChunks(1, 1)
    ).to.be.revertedWithCustomError(lifecycle, "SnapshotAlreadyCompleted");
  });

  it("rejects re-settlement and supports multi-chunk ordering", async () => {
    const { core, lifecycle } = await setup();
    await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());

    // Mark as settled with large openPositionCount to force multiple chunks
    const market = await core.markets(1);
    await core.harnessSetMarket(
      1,
      cloneMarket(market, {
        settled: true,
        openPositionCount: 1025, // ceil(1025/512) = 3 chunks
        snapshotChunkCursor: 0,
        snapshotChunksDone: false,
      })
    );

    await expect(core.finalizePrimarySettlement(1)).to.be.revertedWithCustomError(
      lifecycle,
      "MarketAlreadySettled"
    );

    const tx1 = await core.requestSettlementChunks(1, 2);
    await expect(tx1)
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(1, 0);
    await expect(tx1)
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(1, 1);
    let updated = await core.markets(1);
    expect(updated.snapshotChunkCursor).to.equal(2);
    expect(updated.snapshotChunksDone).to.equal(false);

    const tx2 = await core.requestSettlementChunks(1, 2);
    await expect(tx2)
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(1, 2);
    updated = await core.markets(1);
    expect(updated.snapshotChunkCursor).to.equal(3);
    expect(updated.snapshotChunksDone).to.equal(true);
  });

  it("handles zero open positions and chunk input validation", async () => {
    const { core, lifecycle } = await setup();
    await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());
    const market = await core.markets(1);
    await core.harnessSetMarket(
      1,
      cloneMarket(market, { settled: true, openPositionCount: 0 })
    );

    await expect(
      core.requestSettlementChunks(1, 0)
    ).to.be.revertedWithCustomError(lifecycle, "ZeroLimit");

    const emitted = await core.requestSettlementChunks(1, 5);
    await expect(emitted).to.not.emit(
      lifecycleEvents,
      "SettlementChunkRequested"
    );
    const updated = await core.markets(1);
    expect(updated.snapshotChunksDone).to.equal(true);

    await core.harnessSetMarket(1, cloneMarket(market, { settled: false }));
    await expect(
      core.requestSettlementChunks(1, 1)
    ).to.be.revertedWithCustomError(lifecycle, "MarketNotSettled");
  });
});
