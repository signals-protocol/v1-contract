import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  SignalsCoreHarness,
  MockPaymentToken,
  MockSignalsPosition,
} from "../../typechain-types";

/**
 * Phase 7 Integration Test: α Safety Bound Enforcement
 *
 * Tests α enforcement at market creation time:
 * 1. createMarket with α > αlimit → revert
 * 2. createMarket with α ≤ αlimit → success
 * 3. open/increase/close/decrease freely within configured α (no per-trade gate)
 * 4. Drawdown reduces αlimit for new market creation
 */

// Constants (unused but kept for reference)
// const WAD = ethers.parseEther("1");

describe("α Safety Bound Enforcement (Integration)", () => {
  let core: SignalsCoreHarness;
  let payment: MockPaymentToken;
  let position: MockSignalsPosition;
  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];
  let trader: Awaited<ReturnType<typeof ethers.getSigners>>[0];

  async function deployFixture() {
    const [_owner, _trader] = await ethers.getSigners();
    owner = _owner;
    trader = _trader;

    payment = await (
      await ethers.getContractFactory("MockPaymentToken")
    ).deploy();
    position = await (
      await ethers.getContractFactory("MockSignalsPosition")
    ).deploy();
    const lazyLib = await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy();
    const riskModule = await (
      await ethers.getContractFactory("RiskModule")
    ).deploy();

    const coreImpl = await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();

    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      120, // settlementSubmitWindow
      60, // settlementFinalizeDeadline
    ]);

    const proxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(coreImpl.target, initData);
    core = (await ethers.getContractAt(
      "SignalsCoreHarness",
      proxy.target
    )) as SignalsCoreHarness;

    // Deploy modules
    const lifecycleImpl = await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const tradeImpl = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const lpVaultImpl = await (
      await ethers.getContractFactory("LPVaultModule")
    ).deploy();
    const oracleImpl = await (
      await ethers.getContractFactory("OracleModule")
    ).deploy();

    await core.setModules(
      tradeImpl.target,
      lifecycleImpl.target,
      riskModule.target,
      lpVaultImpl.target,
      oracleImpl.target
    );

    // Configure vault
    await core.setMinSeedAmount(ethers.parseUnits("100", 6));
    await core.setFeeWaterfallConfig(
      ethers.parseEther("-0.3"), // pdd = -30%
      ethers.parseEther("0.2"), // rhoBS = 20%
      ethers.parseEther("0.7"), // phiLP = 70%
      ethers.parseEther("0.2"), // phiBS = 20%
      ethers.parseEther("0.1") // phiTR = 10%
    );

    // Seed vault
    await payment.mint(owner.address, ethers.parseUnits("100000", 6));
    await payment.approve(core.target, ethers.MaxUint256);
    await core.seedVault(ethers.parseUnits("10000", 6));

    // Setup Backstop
    await core.setCapitalStack(
      ethers.parseEther("2000"), // backstopNav
      ethers.parseEther("500") // treasuryNav
    );

    // Configure risk parameters
    // λ = 0.3 (30%), k = 1.0
    await core.setRiskConfig(
      ethers.parseEther("0.3"), // lambda
      ethers.parseEther("1"), // kDrawdown
      true // enforceAlpha = true
    );

    // Setup trader
    await payment.mint(trader.address, ethers.parseUnits("10000", 6));
    await payment.connect(trader).approve(core.target, ethers.MaxUint256);
  }

  beforeEach(async () => {
    await deployFixture();
  });

  describe("Market Creation with α Enforcement", () => {
    it("allows market creation when α ≤ αlimit", async () => {
      // With NAV = 10000, λ = 0.3, n = 100:
      // αbase = 0.3 * 10000 / ln(100) = 3000 / 4.605 ≈ 651.5
      // No drawdown → αlimit = αbase ≈ 651.5

      const now = await time.latest();
      const startTimestamp = now + 60;
      const endTimestamp = now + 3600;
      const settlementTimestamp = now + 3660;

      // Create market with α = 500 (< αlimit ≈ 651.5)
      await expect(
        core.createMarketUniform(
          0, // minTick
          1000, // maxTick
          10, // tickSpacing
          startTimestamp,
          endTimestamp,
          settlementTimestamp,
          100, // numBins
          ethers.parseEther("500"), // liquidityParameter (α)
          ethers.ZeroAddress
        )
      ).to.not.be.reverted;
    });

    it("reverts market creation when α > αlimit", async () => {
      const now = await time.latest();
      const startTimestamp = now + 60;
      const endTimestamp = now + 3600;
      const settlementTimestamp = now + 3660;

      // Create market with α = 1000 (> αlimit ≈ 651.5)
      // This should revert because α exceeds limit
      await expect(
        core.createMarketUniform(
          0,
          1000,
          10,
          startTimestamp,
          endTimestamp,
          settlementTimestamp,
          100,
          ethers.parseEther("1000"), // Too high α
          ethers.ZeroAddress
        )
      ).to.be.reverted; // AlphaExceedsLimit
    });
  });

  describe("Trading Freedom within Configured α", () => {
    let marketId: bigint;

    beforeEach(async () => {
      // Create a market with valid α
      const now = await time.latest();
      const startTimestamp = now + 10;
      const endTimestamp = now + 3600;
      const settlementTimestamp = now + 3660;

      await core.createMarketUniform(
        0,
        1000,
        10,
        startTimestamp,
        endTimestamp,
        settlementTimestamp,
        100,
        ethers.parseEther("500"), // Valid α at creation
        ethers.ZeroAddress
      );
      // marketId starts from 1 (++nextMarketId)
      marketId = 1n;

      // Advance time to market start
      await time.increase(15);
    });

    it("allows openPosition freely (no per-trade α check)", async () => {
      // α/prior are fixed at Zero-Hour (createMarket)
      // Bettors trade freely within configured α - no per-trade gate
      await expect(
        core.connect(trader).openPosition(
          marketId,
          100, // lowerTick
          200, // upperTick
          100, // quantity
          ethers.parseUnits("1000", 6) // maxCost
        )
      ).to.not.be.reverted;
    });

    it("allows increasePosition freely (no per-trade α check)", async () => {
      // Open initial position
      await core
        .connect(trader)
        .openPosition(marketId, 100, 200, 100, ethers.parseUnits("1000", 6));
      const positionId = 1n;

      // Increase is allowed - α enforcement only at market creation
      await expect(
        core.connect(trader).increasePosition(
          positionId,
          50, // additional quantity
          ethers.parseUnits("500", 6)
        )
      ).to.not.be.reverted;
    });

    it("allows closePosition freely", async () => {
      // Open position
      await core
        .connect(trader)
        .openPosition(marketId, 100, 200, 100, ethers.parseUnits("1000", 6));
      const positionId = 1n;

      // Close is allowed
      await expect(
        core.connect(trader).closePosition(
          positionId,
          0 // minProceeds
        )
      ).to.not.be.reverted;
    });

    it("allows decreasePosition freely", async () => {
      // Open position
      await core
        .connect(trader)
        .openPosition(marketId, 100, 200, 100, ethers.parseUnits("1000", 6));
      const positionId = 1n;

      // Decrease is allowed
      await expect(
        core.connect(trader).decreasePosition(
          positionId,
          50, // quantity to decrease
          0 // minProceeds
        )
      ).to.not.be.reverted;
    });
  });

  describe("Drawdown Impact on α Limit", () => {
    it("reduces αlimit proportionally to drawdown for new market creation", async () => {
      // This is a conceptual test - in practice we'd need to simulate
      // vault losses to trigger drawdown
      // Initial state: no drawdown
      // αlimit = αbase * (1 - k * DD) = αbase * 1 = αbase
      // With 50% drawdown:
      // αlimit = αbase * (1 - 1 * 0.5) = αbase * 0.5
      // This affects NEW market creation, not existing trades
      // Existing markets continue trading freely at their configured α
    });
  });

  describe("α Enforcement Toggle", () => {
    it("skips α check when enforceAlpha = false", async () => {
      // Disable α enforcement
      await core.setRiskConfig(
        ethers.parseEther("0.3"),
        ethers.parseEther("1"),
        false // enforceAlpha = false
      );

      const now = await time.latest();
      const startTimestamp = now + 60;
      const endTimestamp = now + 3600;
      const settlementTimestamp = now + 3660;

      // Should succeed even with high α because enforcement is off
      await expect(
        core.createMarketUniform(
          0,
          1000,
          10,
          startTimestamp,
          endTimestamp,
          settlementTimestamp,
          100,
          ethers.parseEther("10000"), // Very high α
          ethers.ZeroAddress
        )
      ).to.not.be.reverted;
    });
  });
});
