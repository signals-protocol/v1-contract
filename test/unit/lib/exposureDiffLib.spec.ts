import { expect } from "chai";
import { ethers } from "hardhat";
import { ExposureDiffLibHarness } from "../../../typechain-types";

describe("ExposureDiffLib", () => {
  let harness: ExposureDiffLibHarness;
  const NUM_BINS = 10;

  beforeEach(async () => {
    const Factory = await ethers.getContractFactory("ExposureDiffLibHarness");
    harness = await Factory.deploy();
    await harness.waitForDeployment();
  });

  describe("rangeAdd", () => {
    it("adds delta to single bin", async () => {
      await harness.rangeAdd(5, 5, 100, NUM_BINS);
      
      // Check diff values
      expect(await harness.getDiff(5)).to.equal(100);
      expect(await harness.getDiff(6)).to.equal(-100);
      
      // Check point query
      expect(await harness.pointQuery(5)).to.equal(100);
      expect(await harness.pointQuery(6)).to.equal(0);
    });

    it("adds delta to range", async () => {
      await harness.rangeAdd(2, 5, 50, NUM_BINS);
      
      // Bins 0-1 should be 0
      expect(await harness.pointQuery(0)).to.equal(0);
      expect(await harness.pointQuery(1)).to.equal(0);
      
      // Bins 2-5 should be 50
      expect(await harness.pointQuery(2)).to.equal(50);
      expect(await harness.pointQuery(3)).to.equal(50);
      expect(await harness.pointQuery(4)).to.equal(50);
      expect(await harness.pointQuery(5)).to.equal(50);
      
      // Bins 6+ should be 0
      expect(await harness.pointQuery(6)).to.equal(0);
    });

    it("handles multiple range adds", async () => {
      await harness.rangeAdd(0, 4, 100, NUM_BINS);
      await harness.rangeAdd(3, 7, 50, NUM_BINS);
      
      // Bins 0-2: only first add
      expect(await harness.pointQuery(0)).to.equal(100);
      expect(await harness.pointQuery(2)).to.equal(100);
      
      // Bins 3-4: both adds overlap
      expect(await harness.pointQuery(3)).to.equal(150);
      expect(await harness.pointQuery(4)).to.equal(150);
      
      // Bins 5-7: only second add
      expect(await harness.pointQuery(5)).to.equal(50);
      expect(await harness.pointQuery(7)).to.equal(50);
      
      // Bins 8+: neither
      expect(await harness.pointQuery(8)).to.equal(0);
    });

    it("handles add to last bin", async () => {
      await harness.rangeAdd(8, 9, 100, NUM_BINS);
      
      expect(await harness.pointQuery(8)).to.equal(100);
      expect(await harness.pointQuery(9)).to.equal(100);
    });

    it("reverts when lo > hi", async () => {
      await expect(
        harness.rangeAdd(5, 3, 100, NUM_BINS)
      ).to.be.revertedWithCustomError(harness, "ExposureDiffInvalidRange");
    });

    it("reverts when hi >= numBins", async () => {
      await expect(
        harness.rangeAdd(0, NUM_BINS, 100, NUM_BINS)
      ).to.be.revertedWithCustomError(harness, "ExposureDiffBinOutOfBounds");
    });

    it("handles zero delta (no-op)", async () => {
      await harness.rangeAdd(2, 5, 0, NUM_BINS);
      
      // All bins should remain 0
      expect(await harness.pointQuery(2)).to.equal(0);
      expect(await harness.pointQuery(5)).to.equal(0);
    });

    it("handles full range (lo=0, hi=numBins-1)", async () => {
      await harness.rangeAdd(0, NUM_BINS - 1, 100, NUM_BINS);
      
      // All bins should be 100
      for (let i = 0; i < NUM_BINS; i++) {
        expect(await harness.pointQuery(i)).to.equal(100);
      }
      
      // diff[hi+1] is not written since hi+1 >= numBins
      // This means the exposure extends to infinity, which is correct
      // since there's no "closing" boundary
    });

    it("verifies diff array pattern for last bin (hi=numBins-1)", async () => {
      // When hi = numBins - 1, diff[hi+1] should NOT be written
      // because hi+1 >= numBins
      await harness.rangeAdd(8, 9, 100, NUM_BINS);
      
      // Check diff values directly
      expect(await harness.getDiff(8)).to.equal(100);
      // diff[10] would be out of bounds, so it's not written
      // diff[9] should be 0 (not -100) because hi+1 = 10 >= NUM_BINS
      // This is handled by the pointQuery returning correct values
      expect(await harness.pointQuery(8)).to.equal(100);
      expect(await harness.pointQuery(9)).to.equal(100);
    });
  });

  describe("subtraction (negative delta)", () => {
    it("handles removal from range", async () => {
      // Add first
      await harness.rangeAdd(2, 6, 100, NUM_BINS);
      // Remove partial
      await harness.rangeAdd(4, 5, -30, NUM_BINS);
      
      expect(await harness.pointQuery(2)).to.equal(100);
      expect(await harness.pointQuery(3)).to.equal(100);
      expect(await harness.pointQuery(4)).to.equal(70);
      expect(await harness.pointQuery(5)).to.equal(70);
      expect(await harness.pointQuery(6)).to.equal(100);
    });
  });

  describe("rawPrefixSum", () => {
    it("returns signed sum", async () => {
      // rangeAdd(0, 2, 50): diff[0] += 50, diff[3] -= 50
      await harness.rangeAdd(0, 2, 50, NUM_BINS);
      // rangeAdd(1, 3, -100): diff[1] += -100, diff[4] -= -100
      await harness.rangeAdd(1, 3, -100, NUM_BINS);
      
      // prefix sums:
      // bin 0: 50
      // bin 1: 50 + (-100) = -50
      // bin 2: 50 + (-100) + 0 = -50
      // bin 3: 50 + (-100) + 0 + (-50) = -100
      // bin 4: 50 + (-100) + 0 + (-50) + 100 = 0
      expect(await harness.rawPrefixSum(0)).to.equal(50);
      expect(await harness.rawPrefixSum(1)).to.equal(-50);
      expect(await harness.rawPrefixSum(2)).to.equal(-50);
      expect(await harness.rawPrefixSum(3)).to.equal(-100);
      expect(await harness.rawPrefixSum(4)).to.equal(0);
    });
  });

  describe("pointQuery negative exposure", () => {
    it("reverts on negative exposure", async () => {
      // Create negative exposure
      await harness.rangeAdd(0, 5, -100, NUM_BINS);
      
      await expect(
        harness.pointQuery(3)
      ).to.be.revertedWithCustomError(harness, "ExposureDiffNegativeExposure");
    });
  });
});

