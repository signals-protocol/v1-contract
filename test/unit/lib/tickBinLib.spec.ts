import { expect } from "chai";
import { ethers } from "hardhat";
import { TickBinLibHarness } from "../../../typechain-types";

describe("TickBinLib", () => {
  let harness: TickBinLibHarness;

  // Market config: range [0, 100) with spacing 10 → 10 bins
  const MIN_TICK = 0n;
  const MAX_TICK = 90n;
  const TICK_SPACING = 10n;
  const NUM_BINS = 10;

  beforeEach(async () => {
    const Factory = await ethers.getContractFactory("TickBinLibHarness");
    harness = await Factory.deploy();
    await harness.waitForDeployment();
  });

  describe("tickToBin", () => {
    it("converts minTick to bin 0", async () => {
      expect(
        await harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, MIN_TICK)
      ).to.equal(0);
    });

    it("converts aligned ticks correctly", async () => {
      expect(await harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 0n)).to.equal(0);
      expect(await harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 10n)).to.equal(1);
      expect(await harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 50n)).to.equal(5);
      expect(await harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 90n)).to.equal(9);
    });

    it("handles negative minTick", async () => {
      const negMinTick = -50n;
      expect(await harness.tickToBin(negMinTick, 10n, 10, -50n)).to.equal(0);
      expect(await harness.tickToBin(negMinTick, 10n, 10, -40n)).to.equal(1);
      expect(await harness.tickToBin(negMinTick, 10n, 10, 0n)).to.equal(5);
      expect(await harness.tickToBin(negMinTick, 10n, 10, 40n)).to.equal(9);
    });

    it("reverts on unaligned tick", async () => {
      await expect(
        harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 15n)
      ).to.be.revertedWithCustomError(harness, "InvalidTickSpacing");
    });

    it("reverts on tick below minTick", async () => {
      await expect(
        harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, -10n)
      ).to.be.revertedWithCustomError(harness, "InvalidTickSpacing");
    });

    it("reverts on bin out of bounds", async () => {
      await expect(
        harness.tickToBin(MIN_TICK, TICK_SPACING, NUM_BINS, 100n)
      ).to.be.revertedWithCustomError(harness, "RangeBinsOutOfBounds");
    });
  });

  describe("ticksToBins", () => {
    it("converts single-bin range", async () => {
      // [0, 10) → [bin 0, bin 0]
      const [lo, hi] = await harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 0n, 10n);
      expect(lo).to.equal(0);
      expect(hi).to.equal(0);
    });

    it("converts multi-bin range", async () => {
      // [20, 60) → [bin 2, bin 5]
      const [lo, hi] = await harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 20n, 60n);
      expect(lo).to.equal(2);
      expect(hi).to.equal(5);
    });

    it("converts full range", async () => {
      // [0, 100) → [bin 0, bin 9]
      const [lo, hi] = await harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 0n, 100n);
      expect(lo).to.equal(0);
      expect(hi).to.equal(9);
    });

    it("handles negative tick range", async () => {
      const negMinTick = -100n;
      const negMaxTick = 90n;
      // [-50, 0) → bins based on offset
      const [lo, hi] = await harness.ticksToBins(negMinTick, negMaxTick, 10n, 20, -50n, 0n);
      expect(lo).to.equal(5);  // (-50 - (-100)) / 10 = 5
      expect(hi).to.equal(9);  // (0 - (-100)) / 10 - 1 = 9
    });

    it("reverts when lowerTick >= upperTick", async () => {
      await expect(
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 50n, 50n)
      ).to.be.revertedWithCustomError(harness, "InvalidTickRange");

      await expect(
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 60n, 50n)
      ).to.be.revertedWithCustomError(harness, "InvalidTickRange");
    });

    it("reverts when lowerTick < minTick", async () => {
      await expect(
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, -10n, 50n)
      ).to.be.revertedWithCustomError(harness, "InvalidTick");
    });

    it("reverts on unaligned lower tick", async () => {
      await expect(
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 5n, 50n)
      ).to.be.revertedWithCustomError(harness, "InvalidTickSpacing");
    });

    it("reverts on unaligned upper tick", async () => {
      await expect(
        harness.ticksToBins(MIN_TICK, MAX_TICK, TICK_SPACING, NUM_BINS, 10n, 55n)
      ).to.be.revertedWithCustomError(harness, "InvalidTickSpacing");
    });
  });
});

