import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

const WAD = ethers.parseEther("1");
const LN_MAX_FACTOR = ethers.parseUnits("4605170185988091368", 0); // ln(100) * 1e18
const MAX_EXP_INPUT = ethers.parseUnits("135305999368893231589", 0); // from FixedPointMathU

describe("SignalsDistributionMath", () => {
  async function deployFixture() {
    // Deploy a test harness that exposes SignalsDistributionMath functions
    const Factory = await ethers.getContractFactory("SignalsDistributionMathHarness");
    const harness = await Factory.deploy();
    await harness.waitForDeployment();
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
  });
});

