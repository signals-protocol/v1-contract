import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { WAD } from "../../helpers/constants";

/**
 * Fixed-Point Math Precision Tests
 * 
 * P0-1: wLn accuracy especially for large values
 * P0-2: Full-range cost = quantity invariant
 * P0-3: Round-trip no-arb invariant
 * 
 * These tests verify mathematical correctness of the fixed-point library.
 * Per whitepaper: CLMSR pricing relies on accurate ln/exp.
 */
describe("FixedPointMath Precision", () => {
  async function deployMathFixture() {
    const mathTest = await (
      await ethers.getContractFactory("FixedPointMathHarness")
    ).deploy();
    return { mathTest };
  }

  // Reference values: ln(x) * 1e18 (computed with high precision)
  // These are the "ground truth" values to compare against
  const LN_REFERENCE: Record<string, bigint> = {
    // ln(1) = 0
    "1": 0n,
    // ln(2) ≈ 0.693147180559945309...
    "2": 693147180559945309n,
    // ln(10) ≈ 2.302585092994045684...
    "10": 2302585092994045684n,
    // ln(100) ≈ 4.605170185988091368...
    "100": 4605170185988091368n,
    // ln(256) ≈ 5.545177444479562475... (MAX_BIN_COUNT case)
    "256": 5545177444479562475n,
    // ln(1000) ≈ 6.907755278982137052...
    "1000": 6907755278982137052n,
  };

  // Maximum allowed relative error: 1e-6 (0.0001%)
  // This is critical for CLMSR pricing - larger errors cause accounting issues
  const MAX_RELATIVE_ERROR = WAD / 1000000n; // 1e12 = 0.0001% of WAD

  describe("wLn Accuracy", () => {
    it("wLn(1) = 0 exactly", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      const result = await mathTest.wLn(WAD);
      expect(result).to.equal(0n);
    });

    it("wLn(2) accuracy within 1e-6 relative error", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      const input = 2n * WAD;
      const expected = LN_REFERENCE["2"];
      const result = await mathTest.wLn(input);
      
      const diff = result > expected ? result - expected : expected - result;
      const relativeError = (diff * WAD) / expected;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR,
        `wLn(2) error too large: ${relativeError} > ${MAX_RELATIVE_ERROR}`
      );
    });

    it("wLn(10) accuracy within 1e-6 relative error", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      const input = 10n * WAD;
      const expected = LN_REFERENCE["10"];
      const result = await mathTest.wLn(input);
      
      const diff = result > expected ? result - expected : expected - result;
      const relativeError = (diff * WAD) / expected;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR,
        `wLn(10) error too large: ${relativeError} > ${MAX_RELATIVE_ERROR}`
      );
    });

    it("wLn(100) accuracy within 1e-6 relative error", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      const input = 100n * WAD;
      const expected = LN_REFERENCE["100"];
      const result = await mathTest.wLn(input);
      
      const diff = result > expected ? result - expected : expected - result;
      const relativeError = (diff * WAD) / expected;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR,
        `wLn(100) error too large: ${relativeError} > ${MAX_RELATIVE_ERROR}`
      );
    });

    it("wLn(256) accuracy within 1e-6 relative error (MAX_BIN_COUNT)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      const input = 256n * WAD;
      const expected = LN_REFERENCE["256"];
      const result = await mathTest.wLn(input);
      
      const diff = result > expected ? result - expected : expected - result;
      const relativeError = (diff * WAD) / expected;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR,
        `wLn(256) error too large: ${relativeError} > ${MAX_RELATIVE_ERROR}`
      );
    });

    it("wLn(1000) accuracy within 1e-6 relative error", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      const input = 1000n * WAD;
      const expected = LN_REFERENCE["1000"];
      const result = await mathTest.wLn(input);
      
      const diff = result > expected ? result - expected : expected - result;
      const relativeError = (diff * WAD) / expected;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR,
        `wLn(1000) error too large: ${relativeError} > ${MAX_RELATIVE_ERROR}`
      );
    });

    it("reverts for x < 1 (ln would be negative)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      await expect(mathTest.wLn(WAD / 2n)).to.be.revertedWithCustomError(
        mathTest,
        "FP_InvalidInput"
      );
    });
  });

  describe("wExp Accuracy", () => {
    // exp and ln should be inverse functions
    it("exp(ln(x)) ≈ x for x in [1, 100] (MAX_FACTOR domain)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // Test across the full factor domain: [1, 100]
      const testValues = [
        2n * WAD,
        5n * WAD,
        10n * WAD,
        20n * WAD,
        50n * WAD,
        100n * WAD, // MAX_FACTOR
      ];
      
      for (const x of testValues) {
        const lnX = await mathTest.wLn(x);
        const expLnX = await mathTest.wExp(lnX);
        
        const diff = expLnX > x ? expLnX - x : x - expLnX;
        const relativeError = (diff * WAD) / x;
        
        expect(relativeError).to.be.lte(
          MAX_RELATIVE_ERROR * 10n,
          `exp(ln(${x / WAD})) round-trip error too large: ${relativeError}`
        );
      }
    });

    it("ln(exp(x)) ≈ x for x in [0, MAX_EXP_INPUT] (full domain)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // Test across the full exp input domain up to ~135 WAD
      const testValues = [
        WAD / 10n,      // 0.1
        WAD / 2n,       // 0.5
        WAD,            // 1
        5n * WAD,       // 5
        10n * WAD,      // 10
        20n * WAD,      // 20
        50n * WAD,      // 50
        100n * WAD,     // 100
        130n * WAD,     // 130 (near MAX_EXP_INPUT)
      ];
      
      for (const x of testValues) {
        const expX = await mathTest.wExp(x);
        const lnExpX = await mathTest.wLn(expX);
        
        const diff = lnExpX > x ? lnExpX - x : x - lnExpX;
        const relativeError = x > 0n ? (diff * WAD) / x : diff;
        
        expect(relativeError).to.be.lte(
          MAX_RELATIVE_ERROR * 10n,
          `ln(exp(${x / WAD})) round-trip error too large: ${relativeError}`
        );
      }
    });

    it("wExp handles MAX_EXP_INPUT without overflow", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // PRBMath MAX_EXP_INPUT_WAD ≈ 133.084... * 1e18
      const maxInput = 133_084258667509499440n;
      
      // Should not revert
      const result = await mathTest.wExp(maxInput);
      expect(result).to.be.gt(0n);
    });

    it("wExp reverts above MAX_EXP_INPUT", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // PRBMath domain: exp(133.084...) is the limit
      const tooLarge = 133_084258667509499440n + WAD;
      await expect(mathTest.wExp(tooLarge)).to.be.revertedWithCustomError(
        mathTest,
        "FP_Overflow"
      );
    });

    it("wExp(100 WAD) works without revert", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // exp(100) ≈ 2.69e43
      const result = await mathTest.wExp(100n * WAD);
      expect(result).to.be.gt(0n);
      
      // exp(100) should be approximately 2.69e43 * 1e18 = 2.69e61 in WAD
      // Just verify it's in the right ballpark
      expect(result).to.be.gt(10n ** 60n);
      expect(result).to.be.lt(10n ** 62n);
    });
  });

  describe("CLMSR Pricing Invariants", () => {
    /**
     * Full-range buy cost invariant:
     * When buying full range (all bins), cost = quantity
     * 
     * This is because:
     * cost = α * ln(Z_after / Z_before)
     * For full-range: Z_after / Z_before = exp(q/α)
     * Therefore: cost = α * ln(exp(q/α)) = q
     */
    it("full-range buy: cost = quantity (ln/exp inverse property)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // Simulate full-range buy
      // ratio = exp(quantity / alpha)
      // cost = alpha * ln(ratio)
      // Should equal quantity
      
      const alpha = WAD; // α = 1 WAD
      const quantity = WAD / 10n; // 0.1 WAD quantity
      
      // Calculate ratio = exp(quantity / alpha) = exp(0.1)
      const expArg = (quantity * WAD) / alpha;
      const ratio = await mathTest.wExp(expArg);
      
      // Calculate cost = alpha * ln(ratio)
      const lnRatio = await mathTest.wLn(ratio);
      const cost = (alpha * lnRatio) / WAD;
      
      // cost should equal quantity (within precision)
      const diff = cost > quantity ? cost - quantity : quantity - cost;
      const relativeError = (diff * WAD) / quantity;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR * 100n, // Allow more error for this composition
        `Full-range cost != quantity: ${cost} vs ${quantity}`
      );
    });

    /**
     * Round-trip no-arbitrage:
     * Buy then immediately sell same quantity should not profit
     * (May lose due to rounding, but never gain)
     */
    it("round-trip: buy+sell should not profit (no arb)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      // Initial Z = 10 * WAD (sum of factors)
      const zBefore = 10n * WAD;
      const alpha = WAD;
      const quantity = WAD / 10n;
      
      // Buy: Z_after_buy = Z_before * exp(q/α)
      const expFactor = await mathTest.wExp((quantity * WAD) / alpha);
      const zAfterBuy = (zBefore * expFactor) / WAD;
      
      // Buy cost = α * ln(Z_after_buy / Z_before)
      const buyRatio = (zAfterBuy * WAD) / zBefore;
      const buyCost = (alpha * (await mathTest.wLn(buyRatio))) / WAD;
      
      // Sell: Z_after_sell = Z_after_buy / exp(q/α) = Z_before (should be same)
      const zAfterSell = (zAfterBuy * WAD) / expFactor;
      
      // Sell proceeds = α * ln(Z_after_buy / Z_after_sell)
      const sellRatio = (zAfterBuy * WAD) / zAfterSell;
      const sellProceeds = (alpha * (await mathTest.wLn(sellRatio))) / WAD;
      
      // Net should be <= 0 (cost >= proceeds)
      const netCashFlow = sellProceeds - buyCost;
      
      expect(netCashFlow).to.be.lte(
        0n,
        `Round-trip arbitrage detected: buy=${buyCost}, sell=${sellProceeds}`
      );
    });
  });

  describe("PnL Calculation Accuracy", () => {
    /**
     * PnL consistency test:
     * ΔC = α * (ln(Z_end) - ln(Z_start))
     * This should equal the accumulated trade costs
     */
    it("ΔC from ln(Z) matches accumulated trades", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      const alpha = WAD;
      const zStart = 256n * WAD; // Initial Z (n bins, all factor=1)
      
      // Simulate a trade: factor increases by exp(q/α)
      const quantity = WAD / 5n; // 0.2 WAD
      const expFactor = await mathTest.wExp((quantity * WAD) / alpha);
      const zEnd = (zStart * expFactor) / WAD;
      
      // Method 1: Trade cost = α * ln(Z_end / Z_start)
      const ratio = (zEnd * WAD) / zStart;
      const tradeCost = (alpha * (await mathTest.wLn(ratio))) / WAD;
      
      // Method 2: ΔC = α * ln(Z_end) - α * ln(Z_start)
      const lnZEnd = await mathTest.wLn(zEnd);
      const lnZStart = await mathTest.wLn(zStart);
      const deltaC = (alpha * (lnZEnd - lnZStart)) / WAD;
      
      // Both methods should give same result
      const diff = tradeCost > deltaC ? tradeCost - deltaC : deltaC - tradeCost;
      const relativeError = tradeCost > 0n ? (diff * WAD) / tradeCost : diff;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR * 10n,
        `PnL methods diverge: tradeCost=${tradeCost}, deltaC=${deltaC}`
      );
    });

    /**
     * Large Z accuracy test:
     * When Z is large (e.g., 256 bins * WAD), ln(Z) must still be accurate
     */
    it("ln(Z) accurate for large Z values (256 bins)", async () => {
      const { mathTest } = await loadFixture(deployMathFixture);
      
      const zLarge = 256n * WAD;
      const expected = LN_REFERENCE["256"];
      const result = await mathTest.wLn(zLarge);
      
      const diff = result > expected ? result - expected : expected - result;
      const relativeError = (diff * WAD) / expected;
      
      expect(relativeError).to.be.lte(
        MAX_RELATIVE_ERROR,
        `ln(256) too inaccurate for PnL: error=${relativeError}`
      );
    });
  });
});

