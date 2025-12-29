import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { buildRedstonePayload, submitWithPayload } from "../../helpers/redstone";
import { deploySeedData } from "../../helpers";

describe("E2E: full lifecycle", () => {
  it("trades, settles, transfers, and claims", async () => {
    const { owner, users, core, payment, position } = await deployFullSystem({
      submitWindow: 5,
      opsWindow: 5,
    });
    const [trader, receiver] = users;
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
    const maxCost = openCost + 1_000_000n;
    await core.connect(trader).openPosition(marketId, 1, 3, quantity, maxCost);

    const traderPositions = await position.getPositionsByOwner(trader.address);
    expect(traderPositions.length).to.equal(1);
    const positionId = traderPositions[0];

    await position
      .connect(trader)
      .transferFrom(trader.address, receiver.address, positionId);

    await time.increaseTo(settlement);
    const payload = await buildRedstonePayload(2, settlement + 1);
    await submitWithPayload(core, receiver, marketId, payload);

    await time.increaseTo(settlement + 6);
    await core.connect(owner).finalizePrimarySettlement(marketId);

    await expect(core.connect(receiver).claimPayout(positionId)).to.be.revertedWithCustomError(
      core,
      "ClaimTooEarly"
    );

    const claimOpen = settlement + 10;
    await time.increaseTo(claimOpen);

    await expect(core.connect(trader).claimPayout(positionId)).to.be.revertedWithCustomError(
      core,
      "UnauthorizedCaller"
    );

    const balanceBefore = await payment.balanceOf(receiver.address);
    await core.connect(receiver).claimPayout(positionId);
    const balanceAfter = await payment.balanceOf(receiver.address);
    expect(balanceAfter).to.be.greaterThan(balanceBefore);

    expect(await position.exists(positionId)).to.equal(false);
  });
});
