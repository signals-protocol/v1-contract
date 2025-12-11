import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployLazyMulSegmentTreeTest } from "../../helpers/deploy";
import { WAD, TWO_WAD, HALF_WAD, MIN_FACTOR, MAX_FACTOR } from "../../helpers/constants";
import { approx, createPrng, randomFactors } from "../../helpers/utils";

describe("LazyMulSegmentTree", () => {
  async function deployFixture() {
    const test = await deployLazyMulSegmentTreeTest();
    return { test };
  }

  async function deploySmallTreeFixture() {
    const test = await deployLazyMulSegmentTreeTest();
    await test.init(10);
    return { test };
  }

  async function deployMediumTreeFixture() {
    const test = await deployLazyMulSegmentTreeTest();
    await test.init(100);
    return { test };
  }

  async function deploySeededTreeFixture() {
    const test = await deployLazyMulSegmentTreeTest();
    // Seed with uniform distribution [1, 1, 1, 1]
    await test.initAndSeed([WAD, WAD, WAD, WAD]);
    return { test };
  }

  // ============================================================
  // Initialization
  // ============================================================
  describe("init", () => {
    it("initializes tree with correct size", async () => {
      const { test } = await loadFixture(deployFixture);
      await test.init(100);
      expect(await test.getTreeSize()).to.equal(100);
    });

    it("reverts on zero size", async () => {
      const { test } = await loadFixture(deployFixture);
      // CE.TreeSizeZero defined in CLMSRErrors
      await expect(test.init(0)).to.be.reverted;
    });

    it("harness allows re-initialization (reset for testing)", async () => {
      // Note: Harness resets tree before init for testing convenience
      // Actual library reverts on double init, but harness overrides this
      const { test } = await loadFixture(deployFixture);
      await test.init(10);
      await test.init(20); // Harness allows this
      expect(await test.getTreeSize()).to.equal(20);
    });

    it("reverts on size too large", async () => {
      const { test } = await loadFixture(deployFixture);
      const maxU32 = 2n ** 32n - 1n;
      // CE.TreeSizeTooLarge defined in CLMSRErrors
      await expect(test.init(maxU32)).to.be.reverted;
    });
  });

  // ============================================================
  // Seeding
  // ============================================================
  describe("initAndSeed", () => {
    it("seeds tree with given factors", async () => {
      const { test } = await loadFixture(deployFixture);
      const factors = [WAD, TWO_WAD, ethers.parseEther("3"), ethers.parseEther("4")];
      await test.initAndSeed(factors);
      
      expect(await test.getTreeSize()).to.equal(4);
      
      // Total sum should be 1 + 2 + 3 + 4 = 10 WAD
      const total = await test.getTotalSum();
      expect(total).to.equal(ethers.parseEther("10"));
    });

    it("reverts on empty factors", async () => {
      const { test } = await loadFixture(deployFixture);
      await expect(test.initAndSeed([])).to.be.reverted;
    });
  });

  // ============================================================
  // Range Sum
  // ============================================================
  describe("getRangeSum", () => {
    it("returns correct sum for single element", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      const sum = await test.getRangeSum(0, 0);
      expect(sum).to.equal(WAD);
    });

    it("returns correct sum for full range", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      const sum = await test.getRangeSum(0, 3);
      expect(sum).to.equal(ethers.parseEther("4"));
    });

    it("returns correct sum for partial range", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      const sum = await test.getRangeSum(1, 2);
      expect(sum).to.equal(TWO_WAD);
    });

    it("reverts on invalid range (lo > hi)", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      // CE.InvalidRange defined in CLMSRErrors
      await expect(test.getRangeSum(3, 1)).to.be.reverted;
    });

    it("reverts on out of bounds index", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      // CE.IndexOutOfBounds defined in CLMSRErrors
      await expect(test.getRangeSum(0, 10)).to.be.reverted;
    });
  });

  // ============================================================
  // Apply Range Factor
  // ============================================================
  describe("applyRangeFactor", () => {
    it("multiplies single element by factor", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      await test.applyRangeFactor(0, 0, TWO_WAD);
      
      const val = await test.getNodeValue(0);
      expect(val).to.equal(TWO_WAD);
      
      // Other elements unchanged
      expect(await test.getNodeValue(1)).to.equal(WAD);
    });

    it("multiplies range by factor", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      await test.applyRangeFactor(0, 3, TWO_WAD);
      
      // All elements doubled: 4 * 2 = 8 WAD total
      const total = await test.getTotalSum();
      expect(total).to.equal(ethers.parseEther("8"));
    });

    it("applies multiple factors correctly", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      
      // First: multiply [0,1] by 2
      await test.applyRangeFactor(0, 1, TWO_WAD);
      // Second: multiply [1,2] by 3
      await test.applyRangeFactor(1, 2, ethers.parseEther("3"));
      
      // Element 0: 1 * 2 = 2
      // Element 1: 1 * 2 * 3 = 6
      // Element 2: 1 * 3 = 3
      // Element 3: 1
      const total = await test.getTotalSum();
      expect(total).to.equal(ethers.parseEther("12"));
    });

    it("reverts on factor below MIN_FACTOR", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      const tooSmall = ethers.parseEther("0.001"); // < 0.01
      // CE.InvalidFactor defined in CLMSRErrors
      await expect(test.applyRangeFactor(0, 0, tooSmall)).to.be.reverted;
    });

    it("reverts on factor above MAX_FACTOR", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      const tooLarge = ethers.parseEther("200"); // > 100
      // CE.InvalidFactor defined in CLMSRErrors
      await expect(test.applyRangeFactor(0, 0, tooLarge)).to.be.reverted;
    });

    it("reverts on invalid range", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      // CE.InvalidRange defined in CLMSRErrors
      await expect(test.applyRangeFactor(3, 1, TWO_WAD)).to.be.reverted;
    });
  });

  // ============================================================
  // Lazy Propagation
  // ============================================================
  describe("Lazy propagation", () => {
    it("handles deferred propagation correctly", async () => {
      const { test } = await loadFixture(deployMediumTreeFixture);
      await test.seedWithFactors(Array(100).fill(WAD));
      
      // Multiple overlapping range operations
      await test.applyRangeFactor(10, 30, TWO_WAD);
      await test.applyRangeFactor(20, 40, ethers.parseEther("3"));
      await test.applyRangeFactor(5, 25, HALF_WAD);
      
      // Query specific values
      // Index 15: 1 * 2 * 0.5 = 1
      expect(await test.getNodeValue(15)).to.equal(WAD);
      
      // Index 25: 1 * 2 * 3 * 0.5 = 3
      approx(await test.getNodeValue(25), ethers.parseEther("3"), 10n);
      
      // Index 35: 1 * 3 = 3
      expect(await test.getNodeValue(35)).to.equal(ethers.parseEther("3"));
      
      // Index 50: unchanged = 1
      expect(await test.getNodeValue(50)).to.equal(WAD);
    });
  });

  // ============================================================
  // Edge Cases
  // ============================================================
  describe("Edge cases", () => {
    it("handles tree of size 1", async () => {
      const { test } = await loadFixture(deployFixture);
      await test.initAndSeed([WAD]);
      
      expect(await test.getTotalSum()).to.equal(WAD);
      
      await test.applyRangeFactor(0, 0, TWO_WAD);
      expect(await test.getTotalSum()).to.equal(TWO_WAD);
    });

    it("handles minimum valid factor (0.01)", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      await test.applyRangeFactor(0, 0, MIN_FACTOR);
      
      // 1 * 0.01 = 0.01
      approx(await test.getNodeValue(0), MIN_FACTOR, 10n);
    });

    it("handles maximum valid factor (100)", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      await test.applyRangeFactor(0, 0, MAX_FACTOR);
      
      // 1 * 100 = 100
      expect(await test.getNodeValue(0)).to.equal(MAX_FACTOR);
    });

    it("handles factor of exactly 1 (no change)", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      const before = await test.getTotalSum();
      await test.applyRangeFactor(0, 3, WAD);
      const after = await test.getTotalSum();
      expect(after).to.equal(before);
    });
  });

  // ============================================================
  // Property: Sum Consistency
  // ============================================================
  describe("Property: sum consistency", () => {
    it("total sum equals sum of all individual nodes", async () => {
      const { test } = await loadFixture(deployMediumTreeFixture);
      const prng = createPrng(42n);
      const factors = randomFactors(prng, 100, MIN_FACTOR, MAX_FACTOR);
      await test.seedWithFactors(factors);
      
      // Calculate expected total
      let expected = 0n;
      for (let i = 0; i < 100; i++) {
        expected += await test.getNodeValue(i);
      }
      
      const total = await test.getTotalSum();
      approx(total, expected, 100n); // Allow small rounding
    });

    it("operations preserve sum consistency", async () => {
      const { test } = await loadFixture(deployMediumTreeFixture);
      await test.seedWithFactors(Array(100).fill(WAD));
      
      const prng = createPrng(123n);
      
      // Apply 10 random range operations
      for (let i = 0; i < 10; i++) {
        const lo = prng.nextInt(100);
        const hi = lo + prng.nextInt(100 - lo);
        const factor = prng.nextInRange(MIN_FACTOR, MAX_FACTOR);
        await test.applyRangeFactor(lo, hi, factor);
      }
      
      // Verify sum consistency
      let computed = 0n;
      for (let i = 0; i < 100; i++) {
        computed += await test.getNodeValue(i);
      }
      
      const total = await test.getTotalSum();
      // Allow larger tolerance due to accumulated WAD rounding
      approx(total, computed, 10000n);
    });
  });

  // ============================================================
  // Property: Monotonicity (buy increases sum)
  // ============================================================
  describe("Property: monotonicity", () => {
    it("factor > 1 increases range sum", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      
      const before = await test.getRangeSum(0, 1);
      await test.applyRangeFactor(0, 1, TWO_WAD);
      const after = await test.getRangeSum(0, 1);
      
      expect(after).to.be.gt(before);
    });

    it("factor < 1 decreases range sum", async () => {
      const { test } = await loadFixture(deploySeededTreeFixture);
      
      const before = await test.getRangeSum(0, 1);
      await test.applyRangeFactor(0, 1, HALF_WAD);
      const after = await test.getRangeSum(0, 1);
      
      expect(after).to.be.lt(before);
    });
  });

  // ============================================================
  // Non-uniform Distribution
  // ============================================================
  describe("Non-uniform distribution", () => {
    it("handles non-uniform initial factors", async () => {
      const { test } = await loadFixture(deployFixture);
      const factors = [
        ethers.parseEther("1"),
        ethers.parseEther("2"),
        ethers.parseEther("4"),
        ethers.parseEther("8"),
      ];
      await test.initAndSeed(factors);
      
      // Total: 1 + 2 + 4 + 8 = 15
      expect(await test.getTotalSum()).to.equal(ethers.parseEther("15"));
      
      // Apply factor to middle range
      await test.applyRangeFactor(1, 2, TWO_WAD);
      
      // New total: 1 + 4 + 8 + 8 = 21
      expect(await test.getTotalSum()).to.equal(ethers.parseEther("21"));
    });
  });
});

