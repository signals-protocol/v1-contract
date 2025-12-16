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

describe("OracleModule", () => {
  async function setup() {
    const [owner, oracleSigner, other] = await ethers.getSigners();
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
      300,
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
      minFactor: WAD, // Phase 7: uniform prior
      deltaEt: 0n, // Uniform prior: ΔEₜ = 0
    };
    await core.harnessSetMarket(1, market);
    // Seed tree for manualSettleFailedMarket tests that need P&L calculation
    await core.harnessSeedTree(1, [
      ethers.parseEther("1"),
      ethers.parseEther("1"),
      ethers.parseEther("1"),
      ethers.parseEther("1"),
    ]);

    const { chainId } = await ethers.provider.getNetwork();

    return {
      owner,
      oracleSigner,
      other,
      core,
      oracleModule,
      market,
      chainId: chainId,
    };
  }

  it("records candidate price with valid signature and window", async () => {
    const { core, oracleModule, oracleSigner, chainId, market } = await setup();
    const oracleEvents = oracleModule.attach(await core.getAddress());
    // Tset = settlementTimestamp, priceTimestamp must be >= Tset
    const priceTimestamp = BigInt(market.settlementTimestamp) + 10n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));

    const digest = buildDigest(
      chainId,
      await core.getAddress(),
      1,
      2n,
      priceTimestamp
    );
    const signature = await oracleSigner.signMessage(ethers.getBytes(digest));

    await expect(core.submitSettlementPrice(1, 2n, priceTimestamp, signature))
      .to.emit(oracleEvents, "SettlementPriceSubmitted")
      .withArgs(1, 2, priceTimestamp, oracleSigner.address);

    const [price, ts] = await core.getSettlementPrice.staticCall(1);
    expect(price).to.equal(2);
    expect(ts).to.equal(priceTimestamp);
  });

  it("reverts on invalid signer", async () => {
    const { core, oracleModule, other, chainId, market } = await setup();
    // Tset = settlementTimestamp
    const priceTimestamp = BigInt(market.settlementTimestamp) + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));

    const digest = buildDigest(
      chainId,
      await core.getAddress(),
      1,
      3n,
      priceTimestamp
    );
    const badSignature = await other.signMessage(ethers.getBytes(digest));

    await expect(
      core.submitSettlementPrice(1, 3n, priceTimestamp, badSignature)
    )
      .to.be.revertedWithCustomError(
        oracleModule,
        "SettlementOracleSignatureInvalid"
      )
      .withArgs(other.address);
  });

  it("enforces submit window bounds", async () => {
    const { core, oracleModule, oracleSigner, chainId, market } = await setup();
    // Tset = settlementTimestamp, price before Tset should revert
    const tooEarlyTs = BigInt(market.settlementTimestamp) - 1n;
    await time.setNextBlockTimestamp(Number(tooEarlyTs + 1n));
    const earlyDigest = buildDigest(
      chainId,
      await core.getAddress(),
      1,
      1n,
      tooEarlyTs
    );
    const earlySig = await oracleSigner.signMessage(
      ethers.getBytes(earlyDigest)
    );

    await expect(
      core.submitSettlementPrice(1, 1n, tooEarlyTs, earlySig)
    ).to.be.revertedWithCustomError(oracleModule, "SettlementTooEarly");

    // submitWindow = 120, price after Tset + 120 should revert
    const lateTs = BigInt(market.settlementTimestamp) + 121n;
    await time.setNextBlockTimestamp(Number(lateTs + 1n));
    const lateDigest = buildDigest(
      chainId,
      await core.getAddress(),
      1,
      1n,
      lateTs
    );
    const lateSig = await oracleSigner.signMessage(ethers.getBytes(lateDigest));

    await expect(
      core.submitSettlementPrice(1, 1n, lateTs, lateSig)
    ).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementFinalizeWindowClosed"
    );
  });

  it("getSettlementPrice reverts when no candidate recorded", async () => {
    const { core, oracleModule } = await setup();
    await expect(core.getSettlementPrice(1)).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementOracleCandidateMissing"
    );
  });

  describe("closest-sample rule", () => {
    it("accepts first candidate", async () => {
      const { core, oracleSigner, chainId, market } = await setup();
      const tSet = BigInt(market.settlementTimestamp);
      const ts1 = tSet + 50n;
      await time.setNextBlockTimestamp(Number(ts1 + 1n));

      const digest = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        100n,
        ts1
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));
      await core.submitSettlementPrice(1, 100n, ts1, sig);

      const [price, priceTs] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(100);
      expect(priceTs).to.equal(ts1);
    });

    it("updates candidate if new one is strictly closer to Tset", async () => {
      const { core, oracleSigner, chainId, market } = await setup();
      const tSet = BigInt(market.settlementTimestamp);

      // First submission: Tset + 50
      const ts1 = tSet + 50n;
      await time.setNextBlockTimestamp(Number(ts1 + 1n));
      const digest1 = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        100n,
        ts1
      );
      const sig1 = await oracleSigner.signMessage(ethers.getBytes(digest1));
      await core.submitSettlementPrice(1, 100n, ts1, sig1);

      // Second submission: Tset + 20 (closer, but block time must be after first block)
      const ts2 = tSet + 20n;
      await time.setNextBlockTimestamp(Number(ts1 + 100n)); // Must be after first submission's block
      const digest2 = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        200n,
        ts2
      );
      const sig2 = await oracleSigner.signMessage(ethers.getBytes(digest2));
      await core.submitSettlementPrice(1, 200n, ts2, sig2);

      const [price, priceTs] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(200); // Updated to closer one
      expect(priceTs).to.equal(ts2);
    });

    it("ignores candidate if new one is farther from Tset", async () => {
      const { core, oracleSigner, chainId, market } = await setup();
      const tSet = BigInt(market.settlementTimestamp);

      // First submission: Tset + 20
      const ts1 = tSet + 20n;
      await time.setNextBlockTimestamp(Number(ts1 + 1n));
      const digest1 = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        100n,
        ts1
      );
      const sig1 = await oracleSigner.signMessage(ethers.getBytes(digest1));
      await core.submitSettlementPrice(1, 100n, ts1, sig1);

      // Second submission: Tset + 50 (farther)
      const ts2 = tSet + 50n;
      await time.setNextBlockTimestamp(Number(ts2 + 1n));
      const digest2 = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        200n,
        ts2
      );
      const sig2 = await oracleSigner.signMessage(ethers.getBytes(digest2));
      await core.submitSettlementPrice(1, 200n, ts2, sig2);

      const [price, priceTs] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(100); // Still the first one
      expect(priceTs).to.equal(ts1);
    });

    it("ignores candidate on tie (prefers earlier submission)", async () => {
      const { core, oracleSigner, chainId, market } = await setup();
      const tSet = BigInt(market.settlementTimestamp);

      // First submission: Tset + 30
      const ts1 = tSet + 30n;
      await time.setNextBlockTimestamp(Number(ts1 + 1n));
      const digest1 = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        100n,
        ts1
      );
      const sig1 = await oracleSigner.signMessage(ethers.getBytes(digest1));
      await core.submitSettlementPrice(1, 100n, ts1, sig1);

      // Second submission: also Tset + 30 (same distance)
      await time.setNextBlockTimestamp(Number(ts1 + 2n));
      const digest2 = buildDigest(
        chainId,
        await core.getAddress(),
        1,
        200n,
        ts1
      );
      const sig2 = await oracleSigner.signMessage(ethers.getBytes(digest2));
      await core.submitSettlementPrice(1, 200n, ts1, sig2);

      const [price, priceTs] = await core.getSettlementPrice.staticCall(1);
      expect(price).to.equal(100); // Still the first one (tie-break)
      expect(priceTs).to.equal(ts1);
    });
  });

  describe("markFailed and secondary settlement", () => {
    it("reverts markFailed before settlement window expires", async () => {
      const { core } = await setup();
      const lifecycle = await ethers.getContractAt(
        "MarketLifecycleModule",
        await core.getAddress()
      );

      // Try to mark failed immediately (window not expired)
      await expect(core.markFailed(1)).to.be.revertedWithCustomError(
        lifecycle,
        "SettlementWindowNotExpired"
      );
    });

    it("allows markFailed after settlement window expires with no valid candidate", async () => {
      const { core, market } = await setup();
      const lifecycle = await ethers.getContractAt(
        "MarketLifecycleModule",
        await core.getAddress()
      );

      const tSet = BigInt(market.settlementTimestamp);
      // submitWindow=120, finalizeDeadline=300 => deadline = tSet + 420
      const deadline = tSet + 420n;
      await time.setNextBlockTimestamp(Number(deadline + 1n));

      await expect(core.markFailed(1))
        .to.emit(lifecycle, "MarketFailed")
        .withArgs(1, Number(deadline + 1n));

      const m = await core.markets(1);
      expect(m.failed).to.equal(true);
      expect(m.isActive).to.equal(false);
    });

    it("reverts manualSettleFailedMarket on non-failed market", async () => {
      const { core } = await setup();
      const lifecycle = await ethers.getContractAt(
        "MarketLifecycleModule",
        await core.getAddress()
      );

      await expect(
        core.manualSettleFailedMarket(1, 100n)
      ).to.be.revertedWithCustomError(lifecycle, "MarketNotFailed");
    });

    it("allows manualSettleFailedMarket on failed market", async () => {
      const { core, market } = await setup();
      const lifecycle = await ethers.getContractAt(
        "MarketLifecycleModule",
        await core.getAddress()
      );

      const tSet = BigInt(market.settlementTimestamp);
      // submitWindow=120, finalizeDeadline=300 => deadline = tSet + 420
      const deadline = tSet + 420n;
      await time.setNextBlockTimestamp(Number(deadline + 1n));
      await core.markFailed(1);

      await time.setNextBlockTimestamp(Number(deadline + 2n));
      await expect(core.manualSettleFailedMarket(1, 2n)).to.emit(
        lifecycle,
        "MarketSettledSecondary"
      );

      const m = await core.markets(1);
      expect(m.settled).to.equal(true);
      expect(m.failed).to.equal(true);
      expect(m.settlementValue).to.equal(2);
    });
  });

  // NOTE: toTick clamping tests (§6.2) are NOT added here because:
  // 1. OracleModule.toTick() conversion logic is NOT yet implemented
  // 2. These tests would fail now and only pass after Phase 5 (Settlement) implementation
  // 3. Per user's instruction: "Phase 4-6 구현하면 깨질 테스트들 추가하지 말라"
  //
  // When implementing Phase 5, add tests for:
  // - Price at L → tick 0
  // - Price below L → clamped to tick 0
  // - Price at/above U → clamped to tick n-1
  // - Tick boundary floor division
});
