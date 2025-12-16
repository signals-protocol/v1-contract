import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  OracleModule,
  SignalsCoreHarness,
} from "../../../typechain-types";
import { ISignalsCore } from "../../../typechain-types/contracts/harness/TradeModuleHarness";

const abiCoder = ethers.AbiCoder.defaultAbiCoder();

function buildDigest(
  chainId: bigint,
  core: string,
  marketId: number,
  settlementValue: bigint,
  priceTimestamp: bigint
) {
  const encoded = abiCoder.encode(
    ["uint256", "address", "uint256", "int256", "uint64"],
    [chainId, core, marketId, settlementValue, priceTimestamp]
  );
  return ethers.keccak256(encoded);
}

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
    minFactor: market.minFactor ?? WAD, // Phase 7: Default to uniform prior
    deltaEt: market.deltaEt ?? 0n, // Phase 7: Default to 0 (uniform prior)
    ...overrides,
  };
}

describe("MarketLifecycleModule", () => {
  async function setup() {
    const [owner, oracleSigner] = await ethers.getSigners();
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
    const oracleModule = (await (
      await ethers.getContractFactory("OracleModule")
    ).deploy()) as OracleModule;

    const coreImpl = (await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as SignalsCoreHarness;

    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      120,
      60,
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
      ethers.ZeroAddress,
      ethers.ZeroAddress,
      oracleModule.target
    );
    await core.setOracleConfig(oracleSigner.address);

    const { chainId } = await ethers.provider.getNetwork();

    return {
      owner,
      oracleSigner,
      core,
      lifecycle: lifecycleImpl,
      oracleModule,
      lazyLib,
      chainId,
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
    await expect(
      core.createMarketUniform(
        0,
        4,
        1,
        Number(start),
        Number(end),
        Number(settlementTs),
        4,
        ethers.parseEther("1"),
        ethers.ZeroAddress
      )
    ).to.emit(lifecycleEvents, "MarketCreated");

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
    const { core, lifecycle, oracleModule, oracleSigner, chainId } =
      await setup();
    const { end } = await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());

    const candidateTs = end + 10n;
    await time.setNextBlockTimestamp(Number(candidateTs + 1n));
    const digest = buildDigest(
      chainId,
      await core.getAddress(),
      1,
      2n,
      candidateTs
    );
    const sig = await oracleSigner.signMessage(ethers.getBytes(digest));
    await core.submitSettlementPrice(1, 2n, candidateTs, sig);

    // set open positions to keep snapshotChunksDone false
    const marketBefore = await core.markets(1);
    await core.harnessSetMarket(
      1,
      cloneMarket(marketBefore, { openPositionCount: 10 })
    );

    await time.setNextBlockTimestamp(Number(candidateTs + 5n));
    await expect(core.settleMarket(1)).to.emit(
      lifecycleEvents,
      "MarketSettled"
    );

    const market = await core.markets(1);
    expect(market.settled).to.equal(true);
    expect(market.settlementValue).to.equal(2);
    expect(market.settlementTick).to.equal(2);
    expect(market.snapshotChunkCursor).to.equal(0);
    expect(market.snapshotChunksDone).to.equal(false);

    await expect(core.getSettlementPrice(1)).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementOracleCandidateMissing"
    );
  });

  it("settleMarket enforces candidate and window checks", async () => {
    const { core, lifecycle, oracleModule, oracleSigner, chainId } =
      await setup();
    const { end } = await createDefaultMarket(core);
    lifecycle.attach(await core.getAddress()); // Attach for event access

    await expect(core.settleMarket(1)).to.be.revertedWithCustomError(
      lifecycle,
      "SettlementOracleCandidateMissing"
    );

    // too early candidate timestamp
    const earlyTs = end - 5n;
    let digest = buildDigest(chainId, await core.getAddress(), 1, 1n, earlyTs);
    let sig = await oracleSigner.signMessage(ethers.getBytes(digest));
    await expect(
      core.submitSettlementPrice(1, 1n, earlyTs, sig)
    ).to.be.revertedWithCustomError(oracleModule, "SettlementTooEarly");

    // too late candidate
    const lateTs = end + 130n; // submit window 120
    digest = buildDigest(chainId, await core.getAddress(), 1, 1n, lateTs);
    sig = await oracleSigner.signMessage(ethers.getBytes(digest));
    await expect(
      core.submitSettlementPrice(1, 1n, lateTs, sig)
    ).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementFinalizeWindowClosed"
    );

    // valid candidate but finalize deadline expired
    const goodTs = end + 10n;
    await time.setNextBlockTimestamp(Number(goodTs + 1n));
    digest = buildDigest(chainId, await core.getAddress(), 1, 1n, goodTs);
    sig = await oracleSigner.signMessage(ethers.getBytes(digest));
    await core.submitSettlementPrice(1, 1n, goodTs, sig);
    await time.setNextBlockTimestamp(Number(goodTs + 100n)); // finalizeDeadline = 60
    await expect(core.settleMarket(1)).to.be.revertedWithCustomError(
      lifecycle,
      "SettlementFinalizeWindowClosed"
    );
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

    const totalChunks = 2; // ceil(1000/512)
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
    expect(updated.snapshotChunkCursor).to.equal(totalChunks);
    expect(updated.snapshotChunksDone).to.equal(true);

    await expect(
      core.requestSettlementChunks(1, 1)
    ).to.be.revertedWithCustomError(lifecycle, "SnapshotAlreadyCompleted");
  });

  it("rejects re-settlement and supports multi-chunk ordering", async () => {
    const { core, lifecycle } = await setup();
    await createDefaultMarket(core);
    const lifecycleEvents = lifecycle.attach(await core.getAddress());

    // mark as settled with large openPositionCount to force multiple chunks
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

    await expect(core.settleMarket(1)).to.be.revertedWithCustomError(
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
