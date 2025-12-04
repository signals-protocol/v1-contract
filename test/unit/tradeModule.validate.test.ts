import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

type MarketStruct = {
  isActive: boolean;
  settled: boolean;
  snapshotChunksDone: boolean;
  numBins: number;
  openPositionCount: number;
  snapshotChunkCursor: number;
  startTimestamp: number;
  endTimestamp: number;
  settlementTimestamp: number;
  minTick: number;
  maxTick: number;
  tickSpacing: number;
  settlementTick: number;
  settlementValue: number;
  liquidityParameter: bigint;
  feePolicy: string;
};

function buildMarket(baseTime: bigint, overrides: Partial<MarketStruct> = {}): MarketStruct {
  const t = Number(baseTime);
  const market: MarketStruct = {
    isActive: true,
    settled: false,
    snapshotChunksDone: false,
    numBins: 4,
    openPositionCount: 0,
    snapshotChunkCursor: 0,
    startTimestamp: t - 10,
    endTimestamp: t + 1_000,
    settlementTimestamp: t + 1_000,
    minTick: 0,
    maxTick: 4,
    tickSpacing: 1,
    settlementTick: 0,
    settlementValue: 0,
    liquidityParameter: ethers.parseEther("1"),
    feePolicy: ethers.ZeroAddress,
  };
  return { ...market, ...overrides };
}

describe("TradeModule validation helpers (Phase 3-1)", () => {
  async function deployHarness() {
    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
    const Factory = await ethers.getContractFactory("TradeModuleHarness", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    });
    return Factory.deploy();
  }

  it("reverts when market does not exist", async () => {
    const harness = await deployHarness();
    await expect(harness.exposedLoadAndValidateMarket(1)).to.be.revertedWithCustomError(
      harness,
      "MarketNotFound"
    );
  });

  it("reverts when market is inactive", async () => {
    const harness = await deployHarness();
    const now = await time.latest();
    await harness.setMarket(1, buildMarket(now, { isActive: false }));

    await expect(harness.exposedLoadAndValidateMarket(1)).to.be.revertedWithCustomError(
      harness,
      "MarketNotActive"
    );
  });

  it("reverts when market has not started or already expired", async () => {
    const harness = await deployHarness();
    const now = await time.latest();

    await harness.setMarket(
      1,
      buildMarket(now, {
        startTimestamp: Number(now) + 100,
        endTimestamp: Number(now) + 1_000,
      })
    );
    await expect(harness.exposedLoadAndValidateMarket(1)).to.be.revertedWithCustomError(
      harness,
      "MarketNotStarted"
    );

    await harness.setMarket(
      2,
      buildMarket(now, {
        startTimestamp: Number(now) - 1_000,
        endTimestamp: Number(now) - 10,
      })
    );
    await expect(harness.exposedLoadAndValidateMarket(2)).to.be.revertedWithCustomError(
      harness,
      "MarketExpired"
    );
  });

  it("reverts on invalid ticks (bounds, spacing, no point bet)", async () => {
    const harness = await deployHarness();
    const now = await time.latest();
    await harness.setMarket(1, buildMarket(now));

    await expect(harness.exposedValidateTickRange(-1, 1, 1)).to.be.revertedWithCustomError(
      harness,
      "InvalidTick"
    );

    await expect(harness.exposedValidateTickRange(0, 5, 1)).to.be.revertedWithCustomError(
      harness,
      "InvalidTick"
    );

    await expect(harness.exposedValidateTickRange(0, 0, 1)).to.be.revertedWithCustomError(
      harness,
      "InvalidTickRange"
    );

    // Misaligned tick spacing
    await harness.setMarket(
      2,
      buildMarket(now, { tickSpacing: 2, maxTick: 10, numBins: 5 })
    );
    await expect(harness.exposedValidateTickRange(1, 3, 2)).to.be.revertedWithCustomError(
      harness,
      "InvalidTickSpacing"
    );
  });

  it("passes validation for aligned, in-range ticks", async () => {
    const harness = await deployHarness();
    const now = await time.latest();
    await harness.setMarket(1, buildMarket(now));

    await harness.exposedValidateTickRange(0, 2, 1);
    await harness.exposedValidateTickRange(1, 3, 1);
  });
});
