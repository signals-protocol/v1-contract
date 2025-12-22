import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { deployClmsrMathHarness } from "../../helpers";

const WAD = ethers.parseEther("1");
const LN_MAX_FACTOR = ethers.parseUnits("4605170185988091368", 0); // ln(100) * 1e18
const MAX_EXP_INPUT = ethers.parseUnits("135305999368893231589", 0); // from FixedPointMathU

describe("ClmsrMath", () => {
  async function deployFixture() {
    const harness = await deployClmsrMathHarness();
    return { harness };
  }

  describe("maxSafeChunkQuantity", () => {
    it("returns tree factor limit for typical alpha (binding constraint)", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      // For α = 1 WAD, maxSafeQty = min(α * ln(100), α * MAX_EXP_INPUT) = ln(100)
      const alpha = WAD;
      const maxSafeQty = await harness.maxSafeChunkQuantity(alpha);
      
      // Should be approximately α * ln(100) since ln(100) < MAX_EXP_INPUT
      expect(maxSafeQty).to.be.closeTo(LN_MAX_FACTOR, LN_MAX_FACTOR / 1000n);
    });

    it("returns 0 for alpha = 0", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const maxSafeQty = await harness.maxSafeChunkQuantity(0);
      expect(maxSafeQty).to.equal(0);
    });

    it("scales linearly with alpha", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha1 = WAD;
      const alpha2 = WAD * 2n;
      
      const qty1 = await harness.maxSafeChunkQuantity(alpha1);
      const qty2 = await harness.maxSafeChunkQuantity(alpha2);
      
      // qty2 should be approximately 2 * qty1
      expect(qty2).to.be.closeTo(qty1 * 2n, qty1 / 100n);
    });

    it("tree limit is binding (ln(100) < MAX_EXP_INPUT)", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      // ln(100) ≈ 4.6, MAX_EXP_INPUT ≈ 135.3
      // Tree limit should always be binding
      const alpha = WAD;
      const maxSafeQty = await harness.maxSafeChunkQuantity(alpha);
      const expLimit = (alpha * MAX_EXP_INPUT) / WAD;
      
      expect(maxSafeQty).to.be.lt(expLimit);
    });
  });

  describe("computeSellProceedsFromSumChange", () => {
    it("returns 0 when sumAfter >= sumBefore", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha = WAD;
      const sumBefore = WAD * 100n;
      const sumAfter = WAD * 100n; // equal
      
      const proceeds = await harness.computeSellProceedsFromSumChange(alpha, sumBefore, sumAfter);
      expect(proceeds).to.equal(0);
      
      const proceeds2 = await harness.computeSellProceedsFromSumChange(alpha, sumBefore, sumAfter + 1n);
      expect(proceeds2).to.equal(0);
    });

    it("computes proceeds correctly for sell", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha = WAD;
      const sumBefore = WAD * 100n;
      const sumAfter = WAD * 50n; // 50% reduction
      
      const proceeds = await harness.computeSellProceedsFromSumChange(alpha, sumBefore, sumAfter);
      
      // proceeds = α * ln(100/50) = α * ln(2) ≈ 0.693 * α
      const expectedLn2 = ethers.parseUnits("693147180559945309", 0); // ln(2) * 1e18
      expect(proceeds).to.be.closeTo(expectedLn2, expectedLn2 / 1000n);
    });

    it("uses floor division (never overpays)", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha = WAD;
      // Edge case: sumBefore / sumAfter has remainder
      const sumBefore = WAD * 100n + 1n;
      const sumAfter = WAD * 100n;
      
      const proceeds = await harness.computeSellProceedsFromSumChange(alpha, sumBefore, sumAfter);
      
      // With floor division, proceeds should be conservative (not overpay)
      // ln(100.000...1 / 100) ≈ 0
      expect(proceeds).to.be.lte(1n); // Very small or 0
    });
  });

  describe("computeBuyCostFromSumChange", () => {
    it("returns 0 when sumAfter <= sumBefore", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha = WAD;
      const sumBefore = WAD * 100n;
      const sumAfter = WAD * 100n; // equal
      
      const cost = await harness.computeBuyCostFromSumChange(alpha, sumBefore, sumAfter);
      expect(cost).to.equal(0);
    });

    it("computes cost correctly for buy", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha = WAD;
      const sumBefore = WAD * 100n;
      const sumAfter = WAD * 200n; // doubled
      
      const cost = await harness.computeBuyCostFromSumChange(alpha, sumBefore, sumAfter);
      
      // cost = α * ln(200/100) = α * ln(2) ≈ 0.693 * α
      const expectedLn2 = ethers.parseUnits("693147180559945309", 0); // ln(2) * 1e18
      expect(cost).to.be.closeTo(expectedLn2, expectedLn2 / 1000n);
    });

    it("returns 0 when sumAfter is slightly larger (within ln precision)", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      const alpha = WAD;
      // Very small increase: ln(100.000...1 / 100) ≈ 0
      const sumBefore = WAD * 100n;
      const sumAfter = WAD * 100n + 1n;
      
      const cost = await harness.computeBuyCostFromSumChange(alpha, sumBefore, sumAfter);
      
      // ln of ratio very close to 1 is essentially 0
      expect(cost).to.equal(0n);
    });
  });

  describe("exposedSafeExp", () => {
    it("computes exp(q/α) correctly", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      // exp(1) = e ≈ 2.718
      const result = await harness.exposedSafeExp(WAD, WAD);
      const expectedE = ethers.parseUnits("2718281828459045235", 0);
      expect(result).to.be.closeTo(expectedE, expectedE / 1000n);
    });

    it("reverts when alpha = 0", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await expect(harness.exposedSafeExp(WAD, 0)).to.be.revertedWithCustomError(
        harness,
        "InvalidLiquidityParameter"
      );
    });

    it("reverts on overflow", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      // q/α > MAX_EXP_INPUT should overflow
      const tooLarge = MAX_EXP_INPUT + WAD;
      await expect(harness.exposedSafeExp(tooLarge, WAD)).to.be.revertedWithCustomError(
        harness,
        "FP_Overflow"
      );
    });
  });

  describe("quoteBuy (calculateTradeCost)", () => {
    it("computes buy cost for range", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      // Seed with uniform distribution [1, 1, 1, 1]
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const alpha = WAD;
      const quantity = WAD / 10n; // 0.1 WAD
      
      // Buy on range [0, 1] (2 bins out of 4)
      const cost = await harness.quoteBuy(alpha, 0, 1, quantity);
      
      // Cost should be positive
      expect(cost).to.be.gt(0n);
      // Cost should be less than quantity (partial range)
      expect(cost).to.be.lt(quantity);
    });

    it("full range buy: cost ≈ quantity", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const alpha = WAD;
      const quantity = WAD / 10n;
      
      // Full range [0, 3]
      const cost = await harness.quoteBuy(alpha, 0, 3, quantity);
      
      // Full range cost ≈ quantity (within tolerance)
      expect(cost).to.be.closeTo(quantity, quantity / 100n);
    });

    it("returns 0 for zero quantity", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const cost = await harness.quoteBuy(WAD, 0, 1, 0n);
      expect(cost).to.equal(0n);
    });
  });

  describe("quoteSell (calculateSellProceeds)", () => {
    it("computes sell proceeds for range", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      // Start with non-uniform: simulate having bought before
      await harness.seed([WAD * 2n, WAD * 2n, WAD, WAD]);
      
      const alpha = WAD;
      const quantity = WAD / 10n;
      
      // Sell on range [0, 1]
      const proceeds = await harness.quoteSell(alpha, 0, 1, quantity);
      
      // Proceeds should be positive
      expect(proceeds).to.be.gt(0n);
    });

    it("returns 0 for zero quantity", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const proceeds = await harness.quoteSell(WAD, 0, 1, 0n);
      expect(proceeds).to.equal(0n);
    });
  });

  describe("quantityFromCost (inverse pricing)", () => {
    it("computes quantity from cost", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const alpha = WAD;
      const targetCost = WAD / 10n;
      
      // Get quantity for given cost on range [0, 1]
      const quantity = await harness.quantityFromCost(alpha, 0, 1, targetCost);
      
      // Quantity should be positive
      expect(quantity).to.be.gt(0n);
    });

    it("returns 0 for zero cost", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const quantity = await harness.quantityFromCost(WAD, 0, 1, 0n);
      expect(quantity).to.equal(0n);
    });
  });

  // ============================================================
  // Edge Cases: Chunking and Overflow
  // ============================================================
  describe("Edge Cases: Large trades and chunking", () => {
    it("handles trade within maxSafeChunkQuantity without chunking", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const alpha = WAD;
      // maxSafeChunkQuantity = α * ln(100) ≈ 4.6 WAD
      const safeQuantity = await harness.maxSafeChunkQuantity(alpha);
      
      // Trade at exactly safe limit should work
      const cost = await harness.quoteBuy(alpha, 0, 1, safeQuantity);
      expect(cost).to.be.gt(0n);
    });

    it("handles trade slightly above maxSafeChunkQuantity (triggers chunking)", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      const alpha = WAD;
      const safeQuantity = await harness.maxSafeChunkQuantity(alpha);
      
      // Trade slightly above safe limit triggers chunking
      const cost = await harness.quoteBuy(alpha, 0, 1, safeQuantity + WAD);
      expect(cost).to.be.gt(0n);
    });

    it("very small alpha does not cause division issues", async () => {
      const { harness } = await loadFixture(deployFixture);
      
      await harness.seed([WAD, WAD, WAD, WAD]);
      
      // Very small alpha: 0.001 WAD
      const smallAlpha = WAD / 1000n;
      const safeQty = await harness.maxSafeChunkQuantity(smallAlpha);
      
      // Safe quantity should scale with alpha
      expect(safeQty).to.be.closeTo(LN_MAX_FACTOR / 1000n, LN_MAX_FACTOR / 10000n);
    });
  });
});

