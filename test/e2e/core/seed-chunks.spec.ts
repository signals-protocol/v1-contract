import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { deploySeedData } from "../../helpers";

describe("E2E: seeding chunks gating", () => {
  it("blocks trading until market is fully seeded", async () => {
    const { owner, users, core, payment } = await deployFullSystem({
      submitWindow: 5,
      opsWindow: 5,
    });
    const [trader] = users;
    const coreAddress = await core.getAddress();

    await core.connect(owner).setMinSeedAmount(1);
    const seedAmount = 20_000_000n;
    await payment.connect(owner).approve(coreAddress, seedAmount);
    await core.connect(owner).seedVault(seedAmount);

    await payment.transfer(trader.address, 50_000_000n);
    await payment.connect(trader).approve(coreAddress, ethers.MaxUint256);

    const now = await time.latest();
    const start = now - 5;
    const end = now + 100;
    const settlement = now + 200;
    const numBins = 6;
    const seedData = await deploySeedData(uniformFactors(numBins));

    const marketId = await core.createMarket.staticCall(
      0,
      numBins,
      1,
      start,
      end,
      settlement,
      numBins,
      ethers.parseEther("1"),
      ethers.ZeroAddress,
      await seedData.getAddress()
    );
    await core.createMarket(
      0,
      numBins,
      1,
      start,
      end,
      settlement,
      numBins,
      ethers.parseEther("1"),
      ethers.ZeroAddress,
      await seedData.getAddress()
    );

    let market = await core.markets(marketId);
    expect(market.isSeeded).to.equal(false);
    expect(market.seedCursor).to.equal(0);

    await core.seedNextChunks(marketId, 2);
    market = await core.markets(marketId);
    expect(market.seedCursor).to.equal(2);
    expect(market.isSeeded).to.equal(false);

    await expect(
      core.connect(trader).openPosition(marketId, 1, 3, 1_000n, 0)
    ).to.be.revertedWithCustomError(core, "MarketNotSeeded");

    await core.seedNextChunks(marketId, 2);
    market = await core.markets(marketId);
    expect(market.seedCursor).to.equal(4);
    expect(market.isSeeded).to.equal(false);

    await core.seedNextChunks(marketId, 10);
    market = await core.markets(marketId);
    expect(market.seedCursor).to.equal(numBins);
    expect(market.isSeeded).to.equal(true);

    const openCost = await core.calculateOpenCost.staticCall(
      marketId,
      1,
      3,
      1_000n
    );
    await expect(
      core
        .connect(trader)
        .openPosition(marketId, 1, 3, 1_000n, openCost + 1_000_000n)
    ).to.not.be.reverted;
  });
});
