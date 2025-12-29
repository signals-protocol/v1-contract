import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { deploySeedData } from "../../helpers";

describe("E2E: risk gate enforcement", () => {
  it("rejects markets that exceed alpha limit when enforced", async () => {
    const { owner, core, payment } = await deployFullSystem({
      submitWindow: 5,
      opsWindow: 5,
    });
    const coreAddress = await core.getAddress();

    await core.connect(owner).setMinSeedAmount(1);
    const seedAmount = 1_000_000n;
    await payment.connect(owner).approve(coreAddress, seedAmount);
    await core.connect(owner).seedVault(seedAmount);

    await core
      .connect(owner)
      .setRiskConfig(ethers.parseEther("0.3"), ethers.parseEther("1"), true);

    const now = await time.latest();
    const start = now - 5;
    const end = now + 5;
    const settlement = now + 10;
    const baseFactors = uniformFactors(4);
    const seedData = await deploySeedData(baseFactors);

    await expect(
      core.connect(owner).createMarket(
        0,
        4,
        1,
        start,
        end,
        settlement,
        4,
        ethers.parseEther("10"),
        ethers.ZeroAddress,
        await seedData.getAddress()
      )
    ).to.be.revertedWithCustomError(core, "AlphaExceedsLimit");

    const marketId = await core.connect(owner).createMarket.staticCall(
      0,
      4,
      1,
      start,
      end,
      settlement + 100,
      4,
      ethers.parseEther("0.1"),
      ethers.ZeroAddress,
      await seedData.getAddress()
    );
    await core.connect(owner).createMarket(
      0,
      4,
      1,
      start,
      end,
      settlement + 100,
      4,
      ethers.parseEther("0.1"),
      ethers.ZeroAddress,
      await seedData.getAddress()
    );

    const market = await core.markets(marketId);
    expect(market.numBins).to.equal(4);
  });
});
