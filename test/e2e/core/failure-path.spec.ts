import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { toSettlementValue } from "../../helpers/redstone";
import { deploySeedData } from "../../helpers";

describe("E2E: failure path", () => {
  it("marks failed, settles secondary, and claims", async () => {
    const { owner, users, core, payment, position } = await deployFullSystem({
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
    const end = now + 50;
    const settlement = now + 60;
    const baseFactors = uniformFactors(4);
    const seedData = await deploySeedData(baseFactors);

    const marketId = await core.createMarket.staticCall(
      0,
      4,
      1,
      start,
      end,
      settlement,
      4,
      ethers.parseEther("1"),
      ethers.ZeroAddress,
      await seedData.getAddress()
    );
    await core.createMarket(
      0,
      4,
      1,
      start,
      end,
      settlement,
      4,
      ethers.parseEther("1"),
      ethers.ZeroAddress,
      await seedData.getAddress()
    );
    await core.seedNextChunks(marketId, 4);

    const quantity = 1_000n;
    const openCost = await core.calculateOpenCost.staticCall(marketId, 1, 3, quantity);
    await core.connect(trader).openPosition(marketId, 1, 3, quantity, openCost + 1_000_000n);

    const traderPositions = await position.getPositionsByOwner(trader.address);
    const positionId = traderPositions[0];

    await time.increaseTo(settlement + 5);
    await core.connect(owner).markSettlementFailed(marketId);

    const settlementValue = toSettlementValue(2);
    await core.connect(owner).finalizeSecondarySettlement(marketId, settlementValue);

    const market = await core.markets(marketId);
    expect(market.failed).to.equal(true);
    expect(market.settled).to.equal(true);

    await time.increaseTo(settlement + 10);
    const balanceBefore = await payment.balanceOf(trader.address);
    await core.connect(trader).claimPayout(positionId);
    const balanceAfter = await payment.balanceOf(trader.address);
    expect(balanceAfter).to.be.greaterThan(balanceBefore);
  });
});
