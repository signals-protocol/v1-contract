import { ethers } from "hardhat";
import { expect } from "chai";
import { deployFullSystem } from "../../helpers/fullSystem";
import { advancePastBatchEnd } from "../../helpers/constants";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("E2E: vault lifecycle", () => {
  const BATCH_SECONDS = 86400n;

  async function createFailedMarketInBatch(core: any, batchId: bigint) {
    const submitWindow = await core.settlementSubmitWindow();
    const now = BigInt(await time.latest());
    const batchStart = batchId * BATCH_SECONDS;
    const batchEnd = (batchId + 1n) * BATCH_SECONDS;

    let settlementTimestamp = batchStart + 1000n;
    if (settlementTimestamp <= now) {
      settlementTimestamp = now + 60n;
    }
    if (settlementTimestamp >= batchEnd) {
      settlementTimestamp = batchEnd - 1n;
    }

    const startTimestamp = settlementTimestamp - 300n;
    const endTimestamp = settlementTimestamp - 100n;

    const baseFactors = Array(10).fill(ethers.parseEther("1"));
    const marketId = await core.createMarket.staticCall(
      0,
      100,
      10,
      startTimestamp,
      endTimestamp,
      settlementTimestamp,
      10,
      ethers.parseEther("100"),
      ethers.ZeroAddress,
      baseFactors
    );
    await core.createMarket(
      0,
      100,
      10,
      startTimestamp,
      endTimestamp,
      settlementTimestamp,
      10,
      ethers.parseEther("100"),
      ethers.ZeroAddress,
      baseFactors
    );

    const opsStart = settlementTimestamp + BigInt(submitWindow) + 1n;
    await time.setNextBlockTimestamp(Number(opsStart));
    await core.markSettlementFailed(marketId);

    return marketId;
  }

  it("seeds, deposits, processes batch, and withdraws", async () => {
    const { owner, users, core, payment, lpShare } = await deployFullSystem({
      submitWindow: 5,
      opsWindow: 5,
      claimDelay: 0,
    });
    const [user] = users;
    const coreAddress = await core.getAddress();

    await core.connect(owner).setMinSeedAmount(1);
    await core
      .connect(owner)
      .setRiskConfig(ethers.parseEther("0.3"), ethers.parseEther("1"), false);
    await core
      .connect(owner)
      .setFeeWaterfallConfig(0, ethers.parseEther("1"), 0, 0);
    const seedAmount = 5_000_000n;
    await payment.connect(owner).approve(coreAddress, seedAmount);
    await core.connect(owner).seedVault(seedAmount);

    const depositAmount = 2_000_000n;
    await payment.transfer(user.address, depositAmount);
    await payment.connect(user).approve(coreAddress, depositAmount);
    const depositRequest = await core.connect(user).requestDeposit(depositAmount);
    const depositReceipt = await depositRequest.wait();
    const depositEvent = depositReceipt?.logs.find((log) => log.topics.length > 0);
    expect(depositEvent).to.not.equal(undefined);

    const currentBatch = await core.getCurrentBatchId();
    const batchId = currentBatch + 1n;
    await createFailedMarketInBatch(core, batchId);
    await advancePastBatchEnd(batchId);
    await core.processDailyBatch(Number(batchId));
    await core.connect(user).claimDeposit(0);

    const shares = await lpShare.balanceOf(user.address);
    expect(shares).to.be.greaterThan(0);

    const withdrawShares = shares / 2n;
    await core.connect(user).requestWithdraw(withdrawShares);

    const nextBatchId = batchId + 1n;
    await createFailedMarketInBatch(core, nextBatchId);
    await advancePastBatchEnd(nextBatchId);
    await core.processDailyBatch(Number(nextBatchId));

    const balanceBefore = await payment.balanceOf(user.address);
    await core.connect(user).claimWithdraw(0);
    const balanceAfter = await payment.balanceOf(user.address);
    expect(balanceAfter).to.be.greaterThan(balanceBefore);
  });
});
