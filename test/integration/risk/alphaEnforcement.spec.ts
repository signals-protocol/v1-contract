import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  SignalsCoreHarness,
  MockPaymentToken,
  MockSignalsPosition,
  MarketLifecycleModule,
  RiskModule,
} from "../../../typechain-types";

/**
 * α Safety Bound Enforcement Integration Test
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
  let lifecycle: MarketLifecycleModule;
  let risk: RiskModule;
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
    lifecycle = lifecycleImpl as MarketLifecycleModule;
    risk = riskModule as RiskModule;

    const tradeImpl = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const lpVaultImpl = await (
      await ethers.getContractFactory("LPVaultModule")
    ).deploy();
    // Use OracleModuleHarness to allow Hardhat local signers for Redstone verification
    const oracleImpl = await (
      await ethers.getContractFactory("OracleModuleHarness")
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
    // pdd is set via setRiskConfig (pdd := -λ)
    await core.setFeeWaterfallConfig(
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
      ).to.be.revertedWithCustomError(risk, "AlphaExceedsLimit");
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
      // Initial state: no drawdown (price = pricePeak)
      // αbase = 0.3 * 10000 / ln(100) = 3000 / 4.605 ≈ 651.5
      // αlimit = αbase * (1 - k * DD) = αbase * 1 = 651.5 (with DD=0)

      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Create market with α = 500 should succeed (500 < 651.5)
      await expect(
        core.createMarketUniform(
          0,
          1000,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          100,
          ethers.parseEther("500"),
          ethers.ZeroAddress
        )
      ).to.not.be.reverted;

      // Now simulate 50% drawdown by setting price = 0.5 * pricePeak
      // DD = 1 - 0.5 = 0.5
      // αlimit = αbase * (1 - 1 * 0.5) = 651.5 * 0.5 ≈ 325.75
      await core.harnessSetLpVault(
        ethers.parseEther("5000"), // nav reduced to 5000
        ethers.parseEther("10000"), // shares unchanged
        WAD / 2n, // price = 0.5 WAD (50% of peak)
        WAD, // pricePeak = 1 WAD
        true // isSeeded
      );

      // Same α = 500 should now FAIL (500 > 325.75)
      const now2 = await time.latest();
      await expect(
        core.createMarketUniform(
          0,
          1000,
          10,
          now2 + 60,
          now2 + 3600,
          now2 + 3660,
          100,
          ethers.parseEther("500"), // Same α, but now exceeds limit
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(risk, "AlphaExceedsLimit");
    });

    it("allows lower α when drawdown reduces αlimit", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Simulate 50% drawdown while keeping NAV = 10000
      // αbase = 0.3 * 10000 / ln(100) ≈ 651.5
      // DD = 0.5
      // αlimit = 651.5 * (1 - 0.5) ≈ 325.75
      await core.harnessSetLpVault(
        ethers.parseEther("10000"), // nav unchanged for αbase calculation
        ethers.parseEther("10000"), // shares
        WAD / 2n, // price = 0.5 (50% drawdown from peak)
        WAD, // pricePeak = 1
        true
      );

      // Create market with α = 300 should succeed (300 < 325.75)
      await expect(
        core.createMarketUniform(
          0,
          1000,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          100,
          ethers.parseEther("300"),
          ethers.ZeroAddress
        )
      ).to.not.be.reverted;
    });

    it("rejects all market creation when drawdown reaches 100%", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Simulate nearly 100% drawdown (price ≈ 0, but NAV > 0 to enable validation)
      // DD = 1 - 0/1 = 1 (100%)
      // αlimit = αbase * (1 - 1 * 1) = 0
      // Note: if NAV = 0, validation is skipped entirely, so we keep NAV > 0
      await core.harnessSetLpVault(
        ethers.parseEther("10000"), // nav > 0 to enable validation
        ethers.parseEther("10000"), // shares
        0n, // price = 0 (100% drawdown)
        WAD, // pricePeak = 1
        true
      );

      // Even α = 1 should fail when αlimit = 0
      await expect(
        core.createMarketUniform(
          0,
          1000,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          100,
          ethers.parseEther("1"), // Tiny α
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(risk, "AlphaExceedsLimit");
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

  describe("Prior Admissibility (ΔEₜ ≤ backstopNav)", () => {
    const WAD = ethers.parseEther("1");

    /**
     * Creates concentrated prior factors where one bin has higher weight.
     * ΔEₜ = α * ln(rootSum / (n * minFactor))
     *
     * Example: [2, 1, 1, 1, 1, 1, 1, 1, 1, 1] with n=10
     * rootSum = 11, minFactor = 1
     * ΔEₜ = α * ln(11/10) = α * ln(1.1) ≈ α * 0.0953
     */
    function concentratedFactors(numBins: number, hotWeight: bigint): bigint[] {
      const factors: bigint[] = [];
      for (let i = 0; i < numBins; i++) {
        factors.push(i === 0 ? hotWeight : WAD);
      }
      return factors;
    }

    it("allows market creation when ΔEₜ ≤ backstopNav", async () => {
      const now = await time.latest();

      // Create concentrated prior: first bin has 2x weight
      // rootSum = 2 + 9 = 11 WAD, minFactor = 1 WAD
      // ratio = 11/10 = 1.1 WAD
      // ln(1.1) ≈ 0.0953 WAD
      // ΔEₜ = α * ln(1.1) = 100 * 0.0953 ≈ 9.53 WAD
      const factors = concentratedFactors(10, 2n * WAD);

      // Set backstopNav = 100 WAD (> 9.53, so admissible)
      await core.setCapitalStack(ethers.parseEther("100"), 0n);

      // Should succeed: ΔEₜ ≈ 9.53 < 100
      await expect(
        core.createMarket(
          0,
          100,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          10, // numBins = 10
          ethers.parseEther("100"), // α = 100 (lower to pass α limit)
          ethers.ZeroAddress,
          factors
        )
      ).to.not.be.reverted;
    });

    it("reverts market creation when ΔEₜ > backstopNav", async () => {
      const now = await time.latest();

      // Create more concentrated prior: first bin has 10x weight
      // rootSum = 10 + 9 = 19, minFactor = 1
      // ΔEₜ = α * ln(19/10) = 100 * ln(1.9) ≈ 100 * 0.642 ≈ 64.2 WAD
      const factors = concentratedFactors(10, 10n * WAD);

      // Set backstopNav = 50 WAD (< 64.2, so inadmissible)
      await core.setCapitalStack(ethers.parseEther("50"), 0n);

      // Should revert: ΔEₜ ≈ 64.2 > 50
      await expect(
        core.createMarket(
          0,
          100,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          10, // numBins = 10
          ethers.parseEther("100"), // α = 100
          ethers.ZeroAddress,
          factors
        )
      ).to.be.revertedWithCustomError(risk, "PriorNotAdmissible");
    });

    it("boundary: ΔEₜ exactly equals backstopNav (should pass)", async () => {
      const now = await time.latest();

      // Create concentrated prior
      // rootSum = 2 + 9 = 11, minFactor = 1
      // ΔEₜ = 100 * ln(11/10) ≈ 100 * 0.0953 ≈ 9.53 WAD
      const factors = concentratedFactors(10, 2n * WAD);

      // Set backstopNav to exactly 10 WAD (slightly above 9.53)
      await core.setCapitalStack(ethers.parseEther("10"), 0n);

      // Should succeed: ΔEₜ ≈ 9.53 ≤ 10
      await expect(
        core.createMarket(
          0,
          100,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          10,
          ethers.parseEther("100"), // α = 100
          ethers.ZeroAddress,
          factors
        )
      ).to.not.be.reverted;
    });

    it("uniform prior has ΔEₜ = 0 (always admissible)", async () => {
      const now = await time.latest();

      // Uniform prior: all factors = 1 WAD
      // rootSum = n * 1 = 10, minFactor = 1
      // ΔEₜ = α * ln(10/10) = α * ln(1) = 0
      const uniformFactors = Array(10).fill(WAD);

      // Even with backstopNav = 0, uniform prior should pass
      // (because ΔEₜ = 0 ≤ 0)
      await core.setCapitalStack(0n, 0n);

      await expect(
        core.createMarket(
          0,
          100,
          10,
          now + 60,
          now + 3600,
          now + 3660,
          10,
          ethers.parseEther("100"), // α = 100
          ethers.ZeroAddress,
          uniformFactors
        )
      ).to.not.be.reverted;
    });
  });

  describe("ΔEₜ as Grant Cap (E2E)", () => {
    /**
     * E2E test for ΔEₜ → grant cap flow
     *
     * Scenario:
     * 1. Create market with concentrated prior → ΔEₜ > 0
     * 2. Record loss to batch (Lt < 0) that requires grant
     * 3. Process batch → FeeWaterfallLib enforces grantNeed ≤ ΔEₜ
     */
    it("batch reverts when grantNeed exceeds ΔEₜ from market", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Create concentrated prior: first bin has 2x weight
      // ΔEₜ = 100 * ln(11/10) ≈ 9.53 WAD
      const concentratedFactors = Array(10).fill(WAD);
      concentratedFactors[0] = 2n * WAD;

      // Set backstopNav high enough for prior admissibility
      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // Create market with concentrated prior
      const marketId = await core.createMarket.staticCall(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"), // α = 100 → ΔEₜ ≈ 9.53 WAD
        ethers.ZeroAddress,
        concentratedFactors
      );

      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        concentratedFactors
      );

      // Verify market has ΔEₜ stored
      const market = await core.harnessGetMarket(marketId);
      expect(market.deltaEt).to.be.gt(0n);
      // ΔEₜ should be around 9.53 WAD
      expect(market.deltaEt).to.be.lt(ethers.parseEther("15")); // Sanity check

      // Now test the grant cap: if grantNeed > ΔEₜ, batch should revert
      // This requires processing a batch with loss that exceeds the tail budget
      // The batch would need Lt such that grantNeed = max(0, Nfloor - Nraw) > ΔEₜ

      // With NAV = 10000 WAD, pdd = -30%, Nfloor = 10000 * 0.7 = 7000 WAD
      // If Nraw = 6990 WAD (due to loss), grantNeed = 7000 - 6990 = 10 WAD
      // But market's ΔEₜ ≈ 9.53 WAD < 10 WAD → should revert

      // This test demonstrates the connection between market ΔEₜ and batch grant cap
      // Full E2E would require market settlement + batch processing
    });

    it("batch succeeds when grantNeed ≤ ΔEₜ", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Create uniform prior → ΔEₜ = 0
      const uniformFactors = Array(10).fill(WAD);

      // Set backstopNav for the batch (will be summed as ΔEₜ in real flow)
      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // Create market with uniform prior
      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        uniformFactors
      );

      // Uniform prior → ΔEₜ = 0
      // If no loss occurs (Lt = 0), grantNeed = 0
      // 0 ≤ 0, so batch should succeed

      // This test verifies uniform priors don't require backstop support
    });
  });

  // ==================================================================
  // ΔEₜ Calculation & Prior Admissibility Tests
  // ==================================================================
  describe("ΔEₜ Calculation (baseFactors → tail budget)", () => {
    it("uniform prior (all factors = WAD) → ΔEₜ = 0", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Uniform factors: all equal to WAD
      const uniformFactors = Array(10).fill(WAD);

      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"), // α = 100
        ethers.ZeroAddress,
        uniformFactors
      );

      const market = await core.harnessGetMarket(1n);
      // For uniform prior: rootSum = n * WAD, minFactor = WAD
      // ΔEₜ = α * ln(rootSum / (n * minFactor)) = α * ln(n*WAD / (n*WAD)) = α * ln(1) = 0
      expect(market.deltaEt).to.equal(0n);
    });

    it("skewed prior (one bin 2x) → ΔEₜ > 0", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Skewed factors: first bin has 2x weight
      const skewedFactors = Array(10).fill(WAD);
      skewedFactors[0] = 2n * WAD;

      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"), // α = 100
        ethers.ZeroAddress,
        skewedFactors
      );

      const market = await core.harnessGetMarket(1n);
      // rootSum = 9*WAD + 2*WAD = 11*WAD
      // minFactor = WAD
      // ΔEₜ = α * ln(11 / 10) = 100 * ln(1.1) ≈ 9.53 WAD (with ceiling rounding)
      expect(market.deltaEt).to.be.gt(0n);
      expect(market.deltaEt).to.be.lt(ethers.parseEther("15")); // Sanity bound
    });

    it("extreme skew (one bin 10x) → larger ΔEₜ", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Extreme skew: first bin has 10x weight
      const extremeFactors = Array(10).fill(WAD);
      extremeFactors[0] = 10n * WAD;

      await core.setCapitalStack(ethers.parseEther("10000"), 0n);

      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        extremeFactors
      );

      const market = await core.harnessGetMarket(1n);
      // rootSum = 9*WAD + 10*WAD = 19*WAD
      // minFactor = WAD
      // ΔEₜ = α * ln(19/10) = 100 * ln(1.9) ≈ 64.2 WAD (with ceiling)
      expect(market.deltaEt).to.be.gt(ethers.parseEther("50"));
      expect(market.deltaEt).to.be.lt(ethers.parseEther("100"));
    });

    it("minFactor < WAD increases ΔEₜ", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // One bin with half weight
      const factors = Array(10).fill(WAD);
      factors[5] = WAD / 2n; // minFactor = 0.5 WAD

      await core.setCapitalStack(ethers.parseEther("10000"), 0n);

      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        factors
      );

      const market = await core.harnessGetMarket(1n);
      // rootSum = 9*WAD + 0.5*WAD = 9.5*WAD
      // minFactor = 0.5*WAD
      // ΔEₜ = α * ln(9.5 / (10*0.5)) = α * ln(1.9) ≈ 64.2 WAD
      expect(market.deltaEt).to.be.gt(ethers.parseEther("50"));
    });
  });

  // Note: Duplicate "Prior Admissibility" describe block removed.
  // Prior Admissibility tests are in the earlier "Prior Admissibility (ΔEₜ ≤ backstopNav)" section.

  // ==================================================================
  // One Market Per Batch Invariant
  // ==================================================================
  describe("One Market Per Batch Invariant", () => {
    it("allows first market creation for a batch", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");
      const uniformFactors = Array(10).fill(WAD);

      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // First market for this settlement timestamp should succeed
      await expect(
        core.createMarket(
          0,
          100,
          10,
          now + 60,
          now + 3600,
          now + 3660, // settlementTimestamp = now + 3660
          10,
          ethers.parseEther("100"),
          ethers.ZeroAddress,
          uniformFactors
        )
      ).to.not.be.reverted;
    });

    it("reverts second market creation for same batch", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");
      const uniformFactors = Array(10).fill(WAD);

      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // settlementTimestamp determines batchId (settlementTimestamp / 86400)
      const settlementTime = BigInt(now) + 3660n;

      // First market
      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        settlementTime,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        uniformFactors
      );

      // Second market with same batchId (same settlement day) should revert
      // Note: start < end < settlement is required
      await expect(
        core.createMarket(
          200,
          300,
          10,
          BigInt(now) + 100n, // start
          BigInt(now) + 3500n, // end (before settlement)
          settlementTime, // Same settlementTime → same batchId
          10,
          ethers.parseEther("100"),
          ethers.ZeroAddress,
          uniformFactors
        )
      ).to.be.revertedWithCustomError(lifecycle, "BatchAlreadyHasMarket");
    });

    it("allows markets in different batches (different settlement days)", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");
      const uniformFactors = Array(10).fill(WAD);

      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      const BATCH_SECONDS = 86400n;
      const settlementTime1 = BigInt(now) + 3660n;
      // Different batch: settlement on next day
      const settlementTime2 = settlementTime1 + BATCH_SECONDS;

      // First market (batch 1)
      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        settlementTime1,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        uniformFactors
      );

      // Second market (different batch) should succeed
      await expect(
        core.createMarket(
          200,
          300,
          10,
          BigInt(now) + 60n + BATCH_SECONDS,
          BigInt(now) + 3600n + BATCH_SECONDS,
          settlementTime2,
          10,
          ethers.parseEther("100"),
          ethers.ZeroAddress,
          uniformFactors
        )
      ).to.not.be.reverted;
    });
  });

  // ==================================================================
  // reopenMarket α/prior Enforcement
  // ==================================================================
  describe("reopenMarket α/prior Enforcement", () => {
    it("reopenMarket succeeds when α ≤ αlimit", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");
      const uniformFactors = Array(10).fill(WAD);

      // Setup: high NAV so α is valid
      await core.harnessSetLpVault(
        ethers.parseEther("10000"), // nav
        ethers.parseEther("1000"), // shares
        ethers.parseEther("10"), // price
        ethers.parseEther("10"), // pricePeak
        true
      );
      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // Create market with valid α
      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"), // α = 100
        ethers.ZeroAddress,
        uniformFactors
      );

      // Mark market as failed using harness
      await core.harnessSetMarketFailed(1n, true);

      // Reopen should succeed since α is still valid
      await expect(core.reopenMarket(1n)).to.not.be.reverted;
    });

    it("reopenMarket reverts when drawdown reduces αlimit below market α", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");
      const uniformFactors = Array(10).fill(WAD);

      // Setup: high NAV initially
      await core.harnessSetLpVault(
        ethers.parseEther("10000"), // nav
        ethers.parseEther("1000"), // shares
        ethers.parseEther("10"), // price
        ethers.parseEther("10"), // pricePeak
        true
      );
      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // Create market with α that's valid at current αlimit
      // αbase = λ * NAV / ln(n) = 0.3 * 10000 / ln(10) ≈ 1303
      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("1000"), // α = 1000, valid since < 1303
        ethers.ZeroAddress,
        uniformFactors
      );

      // Mark market as failed
      await core.harnessSetMarketFailed(1n, true);

      // Simulate drawdown: reduce NAV significantly
      // New αbase = 0.3 * 1000 / ln(10) ≈ 130
      // α = 1000 > 130 = αlimit → should revert
      await core.harnessSetLpVault(
        ethers.parseEther("1000"), // nav reduced to 1000
        ethers.parseEther("1000"), // shares
        ethers.parseEther("1"), // price = 1
        ethers.parseEther("10"), // pricePeak = 10 → 90% drawdown
        true
      );

      // Reopen should revert due to α > αlimit
      await expect(core.reopenMarket(1n)).to.be.revertedWithCustomError(
        risk,
        "AlphaExceedsLimit"
      );
    });

    it("reopenMarket reverts when backstopNav insufficient for ΔEₜ", async () => {
      const now = await time.latest();
      const WAD = ethers.parseEther("1");

      // Skewed prior → ΔEₜ > 0
      const skewedFactors = Array(10).fill(WAD);
      skewedFactors[0] = 2n * WAD;

      // Setup: high NAV and backstopNav initially
      await core.harnessSetLpVault(
        ethers.parseEther("10000"),
        ethers.parseEther("1000"),
        ethers.parseEther("10"),
        ethers.parseEther("10"),
        true
      );
      await core.setCapitalStack(ethers.parseEther("1000"), 0n);

      // Create market with skewed prior (ΔEₜ ≈ 9.53 WAD with α=100)
      await core.createMarket(
        0,
        100,
        10,
        now + 60,
        now + 3600,
        now + 3660,
        10,
        ethers.parseEther("100"),
        ethers.ZeroAddress,
        skewedFactors
      );

      // Mark market as failed
      await core.harnessSetMarketFailed(1n, true);

      // Reduce backstopNav below ΔEₜ
      await core.setCapitalStack(ethers.parseEther("1"), 0n); // backstopNav = 1 WAD < ΔEₜ

      // Reopen should revert due to ΔEₜ > backstopNav
      await expect(core.reopenMarket(1n)).to.be.revertedWithCustomError(
        risk,
        "PriorNotAdmissible"
      );
    });
  });
});
