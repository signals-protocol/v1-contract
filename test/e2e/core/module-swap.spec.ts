import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { buildRedstonePayload, submitWithPayload } from "../../helpers/redstone";
import { deploySeedData } from "../../helpers";

describe("E2E: module hot-swap", () => {
  it("keeps state consistent after swapping trade/lifecycle modules", async () => {
    const {
      owner,
      users,
      core,
      payment,
      position,
      riskModule,
      vaultModule,
      oracleModule,
      lazyLibrary,
    } = await deployFullSystem({
      submitWindow: 5,
      opsWindow: 5,
    });
    const [userA, userB] = users;
    const coreAddress = await core.getAddress();

    await core.connect(owner).setMinSeedAmount(1);
    const seedAmount = 20_000_000n;
    await payment.connect(owner).approve(coreAddress, seedAmount);
    await core.connect(owner).seedVault(seedAmount);

    await payment.transfer(userA.address, 50_000_000n);
    await payment.transfer(userB.address, 50_000_000n);
    await payment.connect(userA).approve(coreAddress, ethers.MaxUint256);
    await payment.connect(userB).approve(coreAddress, ethers.MaxUint256);

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

    const qtyA = 1_000n;
    const costA = await core.calculateOpenCost.staticCall(marketId, 1, 3, qtyA);
    await core.connect(userA).openPosition(marketId, 1, 3, qtyA, costA + 1_000_000n);

    const newTradeModule = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLibrary },
      })
    ).deploy();
    const newLifecycleModule = await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLibrary },
      })
    ).deploy();

    await core.setModules(
      newTradeModule.target,
      newLifecycleModule.target,
      riskModule.target,
      vaultModule.target,
      oracleModule.target
    );

    const qtyB = 2_000n;
    const costB = await core.calculateOpenCost.staticCall(marketId, 1, 3, qtyB);
    await core.connect(userB).openPosition(marketId, 1, 3, qtyB, costB + 1_000_000n);

    const [posA] = await position.getPositionsByOwner(userA.address);
    const [posB] = await position.getPositionsByOwner(userB.address);

    await time.increaseTo(settlement);
    const payload = await buildRedstonePayload(2, settlement + 1);
    await submitWithPayload(core, userA, marketId, payload);

    await time.increaseTo(settlement + 5 + 5 + 1);
    await core.connect(owner).finalizePrimarySettlement(marketId);

    await core.connect(userA).claimPayout(posA);
    await core.connect(userB).claimPayout(posB);

    expect(await position.exists(posA)).to.equal(false);
    expect(await position.exists(posB)).to.equal(false);
  });
});
