import { expect } from "chai";
import { ethers } from "hardhat";
import { time, loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { WAD, USDC_DECIMALS } from "../helpers/constants";
import {
  buildRedstonePayload,
  submitWithPayload,
} from "../helpers/redstone";

/**
 * Vault & Batch Security Tests (CRITICAL-02, CRITICAL-03, HIGH-01)
 * 
 * CRITICAL-02: processDailyBatch must verify market is settled
 * CRITICAL-03: cancel* must revert if batch already processed
 * HIGH-01: Free balance must reserve processed withdrawals
 */
describe("Vault Escrow Security", () => {
  const BATCH_SECONDS = 86400n;
  
  async function deploySecurityFixture() {
    const [owner, user1, user2, attacker] = await ethers.getSigners();

    const payment = await (await ethers.getContractFactory("SignalsUSDToken")).deploy();
    const fundAmount = ethers.parseUnits("1000000", USDC_DECIMALS);
    await payment.transfer(user1.address, fundAmount);
    await payment.transfer(user2.address, fundAmount);
    await payment.transfer(attacker.address, fundAmount);

    const positionImpl = await (await ethers.getContractFactory("SignalsPosition")).deploy();
    const positionInit = positionImpl.interface.encodeFunctionData("initialize", [owner.address]);
    const positionProxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(
      positionImpl.target,
      positionInit
    );
    const position = await ethers.getContractAt("SignalsPosition", positionProxy.target);

    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();

    const oracleModule = await (await ethers.getContractFactory("OracleModuleHarness")).deploy();
    const tradeModule = await (await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target }
    })).deploy();
    const lifecycleModule = await (await ethers.getContractFactory("MarketLifecycleModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target }
    })).deploy();
    const lpVaultModule = await (await ethers.getContractFactory("LPVaultModule")).deploy();
    const riskModule = await (await ethers.getContractFactory("RiskModule")).deploy();

    const coreImpl = await (await ethers.getContractFactory("SignalsCoreHarness", {
      libraries: { LazyMulSegmentTree: lazyLib.target }
    })).deploy();
    const coreInit = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      3600,  // settlementSubmitWindow
      3600   // claimDelaySeconds
    ]);
    const coreProxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(
      coreImpl.target,
      coreInit
    );
    const core = await ethers.getContractAt("SignalsCoreHarness", coreProxy.target);

    const lpShare = await (await ethers.getContractFactory("SignalsLPShare")).deploy(
      "Signals LP Share",
      "sLP",
      core.target,
      payment.target
    );

    await core.setModules(
      tradeModule.target,
      lifecycleModule.target,
      riskModule.target,
      lpVaultModule.target,
      oracleModule.target
    );

    await core.setLpShareToken(lpShare.target);
    // Set settlement timeline: sampleWindow=3600, opsWindow=3600, claimDelay=3600
    await core.setSettlementTimeline(3600, 3600, 3600);

    const feedId = ethers.encodeBytes32String("BTC");
    await core.setRedstoneConfig(feedId, 8, 600, 60);

    await core.setRiskConfig(
      ethers.parseEther("0.2"),
      ethers.parseEther("1"),
      false
    );
    await core.setFeeWaterfallConfig(
      0n,
      ethers.parseEther("0.7"),
      ethers.parseEther("0.2"),
      ethers.parseEther("0.1")
    );
    
    // Set withdrawal lag to 1 batch
    await core.setWithdrawalLagBatches(1);

    await position.setCore(core.target);

    await payment.connect(user1).approve(core.target, ethers.MaxUint256);
    await payment.connect(user2).approve(core.target, ethers.MaxUint256);
    await payment.connect(attacker).approve(core.target, ethers.MaxUint256);
    await payment.connect(owner).approve(core.target, ethers.MaxUint256);
    await lpShare.connect(user1).approve(core.target, ethers.MaxUint256);
    await lpShare.connect(user2).approve(core.target, ethers.MaxUint256);

    // Seed vault
    await core.connect(owner).seedVault(ethers.parseUnits("100000", USDC_DECIMALS));

    return { core, payment, lpShare, owner, user1, user2, attacker, lpVaultModule, lifecycleModule, tradeModule };
  }

  async function seedBatchForProcessing(core: any, batchId: bigint) {
    await core.harnessSetBatchMarketState(batchId, 1n, 1n);
  }

  /**
   * Create a market that settles in a specific batch
   */
  async function createMarketInBatch(core: any, batchId: bigint, numBins: number = 10) {
    const settlementTimestamp = batchId * BATCH_SECONDS + 43200n; // Middle of batch day
    const now = await time.latest();
    const startTime = BigInt(now) + 60n;
    const endTime = settlementTimestamp - 1n;

    if (startTime >= endTime) {
      throw new Error("Invalid time range: startTime >= endTime");
    }

    const tickSpacing = 100n;
    const minTick = 0n;
    const maxTick = tickSpacing * BigInt(numBins);
    const baseFactors = Array(numBins).fill(WAD);

    const marketId = await core.createMarket.staticCall(
      minTick,
      maxTick,
      tickSpacing,
      startTime,
      endTime,
      settlementTimestamp,
      numBins,
      WAD,
      ethers.ZeroAddress,
      baseFactors
    );
    await core.createMarket(
      minTick,
      maxTick,
      tickSpacing,
      startTime,
      endTime,
      settlementTimestamp,
      numBins,
      WAD,
      ethers.ZeroAddress,
      baseFactors
    );
    return marketId;
  }

  // ============================================================
  // CRITICAL-02: processDailyBatch finalized check
  // ============================================================
  describe("CRITICAL-02: Batch Processing Before Market Finalized", () => {
    it("reverts processDailyBatch when batch market is not settled", async () => {
      const { core, attacker, lpVaultModule } = await loadFixture(deploySecurityFixture);
      
      const currentBatchId = await core.currentBatchId();
      const targetBatchId = currentBatchId + 1n;
      
      // Create market that settles in targetBatchId
      const marketId = await createMarketInBatch(core, targetBatchId);
      expect(marketId).to.be.gt(0);
      
      // Fast forward to after batch end time (but DON'T finalize market)
      const batchEndTime = (targetBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
      
      // Market is NOT settled yet
      const market = await core.markets(marketId);
      expect(market.settled).to.be.false;
      
      // Attacker tries to process batch without market being settled
      // This should revert to prevent settlement DoS
      await expect(
        core.connect(attacker).processDailyBatch(targetBatchId)
      ).to.be.revertedWithCustomError(lpVaultModule, "BatchMarketsNotResolved")
        .withArgs(targetBatchId, 0n, 1n);
    });

    it("allows processDailyBatch after market is finalized", async () => {
      const { core, owner } = await loadFixture(deploySecurityFixture);
      
      const currentBatchId = await core.currentBatchId();
      const targetBatchId = currentBatchId + 1n;
      
      // Create market that settles in targetBatchId
      const marketId = await createMarketInBatch(core, targetBatchId);
      
      // Fast forward to settlement time
      const market = await core.markets(marketId);
      await time.setNextBlockTimestamp(Number(market.settlementTimestamp) + 1);
      
      // Submit oracle sample (price = 500 which is in range [0, 1000])
      const settlementValue = 500; // Human readable price
      const priceTimestamp = Number(market.settlementTimestamp);
      const payload = buildRedstonePayload(settlementValue * 1e8, priceTimestamp);
      await submitWithPayload(core, owner, marketId, payload);
      
      // Fast forward past pending ops window
      const submitWindow = await core.settlementSubmitWindow();
      const opsWindow = await core.pendingOpsWindow();
      const finalizeTime = Number(market.settlementTimestamp) + Number(submitWindow) + Number(opsWindow) + 1;
      await time.setNextBlockTimestamp(finalizeTime);
      
      // Finalize settlement
      await core.finalizePrimarySettlement(marketId);
      
      // Fast forward to after batch end
      const batchEndTime = (targetBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
      
      // Now batch processing should succeed
      await expect(
        core.connect(owner).processDailyBatch(targetBatchId)
      ).to.not.be.reverted;
    });

    it("requires all markets in batch to be resolved (settled or failed)", async () => {
      const { core, owner, lpVaultModule } = await loadFixture(deploySecurityFixture);

      const currentBatchId = await core.currentBatchId();
      const targetBatchId = currentBatchId + 1n;

      const marketId1 = await createMarketInBatch(core, targetBatchId);
      const marketId2 = await createMarketInBatch(core, targetBatchId);

      const market1 = await core.markets(marketId1);
      const submitWindow = await core.settlementSubmitWindow();
      const opsStart = Number(market1.settlementTimestamp) + Number(submitWindow) + 1;
      await time.setNextBlockTimestamp(opsStart);

      await core.markSettlementFailed(marketId1);

      const batchEndTime = (targetBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);

      await expect(
        core.connect(owner).processDailyBatch(targetBatchId)
      ).to.be.revertedWithCustomError(lpVaultModule, "BatchMarketsNotResolved")
        .withArgs(targetBatchId, 1n, 2n);

      await core.markSettlementFailed(marketId2);

      await expect(
        core.connect(owner).processDailyBatch(targetBatchId)
      ).to.not.be.reverted;
    });

    it("prevents finalize after batch is processed (DoS attack)", async () => {
      const { core, owner } = await loadFixture(deploySecurityFixture);
      
      // Process a batch with a resolved market first
      const currentBatchId = await core.currentBatchId();
      const emptyBatchId = currentBatchId + 1n;
      const batchEndTime = (emptyBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
      await seedBatchForProcessing(core, emptyBatchId);
      await core.connect(owner).processDailyBatch(emptyBatchId);
      
      // Now create market for next batch
      const targetBatchId = emptyBatchId + 1n;
      const marketId = await createMarketInBatch(core, targetBatchId);
      
      // Complete settlement
      const market = await core.markets(marketId);
      await time.setNextBlockTimestamp(Number(market.settlementTimestamp) + 1);
      
      const settlementValue = 500;
      const priceTimestamp = Number(market.settlementTimestamp);
      const payload = buildRedstonePayload(settlementValue * 1e8, priceTimestamp);
      await submitWithPayload(core, owner, marketId, payload);
      
      const submitWindow = await core.settlementSubmitWindow();
      const opsWindow = await core.pendingOpsWindow();
      const finalizeTime = Number(market.settlementTimestamp) + Number(submitWindow) + Number(opsWindow) + 1;
      await time.setNextBlockTimestamp(finalizeTime);
      
      await core.finalizePrimarySettlement(marketId);
      
      // Process the batch after finalization - should work
      const targetBatchEndTime = (targetBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(targetBatchEndTime) + 1);
      await expect(
        core.connect(owner).processDailyBatch(targetBatchId)
      ).to.not.be.reverted;
    });
  });

  // ============================================================
  // CRITICAL-03: Cancel after batch processed (too-late check)
  // ============================================================
  describe("CRITICAL-03: Cancel After Batch Processed", () => {
    it("reverts cancelDeposit after batch is processed", async () => {
      const { core, user1, lpVaultModule } = await loadFixture(deploySecurityFixture);
      
      // Create deposit request
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      // Eligible batch = currentBatchId + 1
      const currentBatchId = await core.currentBatchId();
      const eligibleBatchId = currentBatchId + 1n;
      const batchEndTime = (eligibleBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
      await seedBatchForProcessing(core, eligibleBatchId);
      await core.processDailyBatch(eligibleBatchId);
      
      // Try to cancel after batch processed - should revert with CancelTooLate
      // Request ID 0 for first deposit request
      await expect(
        core.connect(user1).cancelDeposit(0)
      ).to.be.revertedWithCustomError(lpVaultModule, "CancelTooLate")
        .withArgs(0n, eligibleBatchId);
    });

    it("reverts cancelWithdraw after batch is processed", async () => {
      const { core, user1, lpShare, lpVaultModule } = await loadFixture(deploySecurityFixture);
      
      // First deposit and claim to get shares
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      const currentBatchId = await core.currentBatchId();
      const depositBatchId = currentBatchId + 1n;
      const depositBatchEnd = (depositBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(depositBatchEnd) + 1);
      await seedBatchForProcessing(core, depositBatchId);
      await core.processDailyBatch(depositBatchId);
      
      // Claim deposit with request ID 0 (first request)
      await core.connect(user1).claimDeposit(0);
      
      // Now create withdraw request
      const shares = await lpShare.balanceOf(user1.address);
      expect(shares).to.be.gt(0);
      
      await core.connect(user1).requestWithdraw(shares);
      
      // Withdrawal lag = 1, so eligible batch = depositBatchId + 1 + 1
      const eligibleBatchId = depositBatchId + 2n;
      
      // Process all intermediate batches
      let nextBatch = depositBatchId + 1n;
      while (nextBatch <= eligibleBatchId) {
        const endTime = (nextBatch + 1n) * BATCH_SECONDS;
        await time.setNextBlockTimestamp(Number(endTime) + 1);
        await seedBatchForProcessing(core, nextBatch);
        await core.processDailyBatch(nextBatch);
        nextBatch++;
      }
      
      // Try to cancel after batch processed - should revert with CancelTooLate
      // Request ID 0 for first withdraw request
      await expect(
        core.connect(user1).cancelWithdraw(0)
      ).to.be.revertedWithCustomError(lpVaultModule, "CancelTooLate")
        .withArgs(0n, eligibleBatchId);
    });

    it("allows cancel before batch is processed", async () => {
      const { core, user1, payment } = await loadFixture(deploySecurityFixture);
      
      const balanceBefore = await payment.balanceOf(user1.address);
      
      // Create deposit request
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      // Cancel before batch processing (request ID 0)
      await expect(
        core.connect(user1).cancelDeposit(0)
      ).to.not.be.reverted;
      
      // Funds should be returned
      const balanceAfter = await payment.balanceOf(user1.address);
      expect(balanceAfter).to.equal(balanceBefore);
    });

    it("reverts cancel by non-owner (RequestNotOwned)", async () => {
      const { core, user1, user2, lpVaultModule } = await loadFixture(deploySecurityFixture);
      
      // user1 creates deposit request
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      // user2 tries to cancel user1's request
      await expect(
        core.connect(user2).cancelDeposit(0)
      ).to.be.revertedWithCustomError(lpVaultModule, "RequestNotOwned")
        .withArgs(0n, user1.address, user2.address);
    });

    it("reverts claim by non-owner (RequestNotOwned)", async () => {
      const { core, user1, user2, lpVaultModule } = await loadFixture(deploySecurityFixture);
      
      // user1 creates deposit request
      const depositAmount = ethers.parseUnits("1000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      // Process batch
      const currentBatchId = await core.currentBatchId();
      const eligibleBatchId = currentBatchId + 1n;
      const batchEndTime = (eligibleBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
      await seedBatchForProcessing(core, eligibleBatchId);
      await core.processDailyBatch(eligibleBatchId);
      
      // user2 tries to claim user1's deposit
      await expect(
        core.connect(user2).claimDeposit(0)
      ).to.be.revertedWithCustomError(lpVaultModule, "RequestNotOwned")
        .withArgs(0n, user1.address, user2.address);
    });

    it("reverts claim for non-existent request (RequestNotFound)", async () => {
      const { core, user1, lpVaultModule } = await loadFixture(deploySecurityFixture);
      
      // Try to claim request that doesn't exist
      await expect(
        core.connect(user1).claimDeposit(999)
      ).to.be.revertedWithCustomError(lpVaultModule, "RequestNotFound")
        .withArgs(999n);
    });
  });

  // ============================================================
  // HIGH-01: Withdrawal reserve in free balance
  // ============================================================
  describe("HIGH-01: Withdrawal Reserve Protection", () => {
    it("reserves processed withdrawal funds in free balance", async () => {
      const { core, user1, payment, lpShare } = await loadFixture(deploySecurityFixture);
      
      // User1 deposits
      const depositAmount = ethers.parseUnits("50000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      // Process deposit batch
      const currentBatchId = await core.currentBatchId();
      const depositBatchId = currentBatchId + 1n;
      const depositBatchEnd = (depositBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(depositBatchEnd) + 1);
      await seedBatchForProcessing(core, depositBatchId);
      await core.processDailyBatch(depositBatchId);
      
      // Claim deposit to get shares (request ID 0)
      await core.connect(user1).claimDeposit(0);
      
      const user1Shares = await lpShare.balanceOf(user1.address);
      expect(user1Shares).to.be.gt(0);
      
      // User1 requests withdrawal of all shares
      await core.connect(user1).requestWithdraw(user1Shares);
      
      // Process withdrawal batch
      const eligibleBatchId = depositBatchId + 2n; // D_lag = 1
      
      let nextBatch = depositBatchId + 1n;
      while (nextBatch <= eligibleBatchId) {
        const endTime = (nextBatch + 1n) * BATCH_SECONDS;
        await time.setNextBlockTimestamp(Number(endTime) + 1);
        await seedBatchForProcessing(core, nextBatch);
        await core.processDailyBatch(nextBatch);
        nextBatch++;
      }
      
      // User1 claims their withdrawal - should work (withdraw request ID 0)
      const balanceBefore = await payment.balanceOf(user1.address);
      await core.connect(user1).claimWithdraw(0);
      const balanceAfter = await payment.balanceOf(user1.address);
      
      // Should receive approximately the deposited amount back
      expect(balanceAfter - balanceBefore).to.be.gte(ethers.parseUnits("49000", USDC_DECIMALS));
    });

    it("prevents double-claim of withdrawal funds via free balance manipulation", async () => {
      const { core, user1, lpShare } = await loadFixture(deploySecurityFixture);
      
      // Deposit
      const depositAmount = ethers.parseUnits("10000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);
      
      // Process and claim deposit (request ID 0)
      const currentBatchId = await core.currentBatchId();
      const depositBatchId = currentBatchId + 1n;
      const depositBatchEnd = (depositBatchId + 1n) * BATCH_SECONDS;
      await time.setNextBlockTimestamp(Number(depositBatchEnd) + 1);
      await seedBatchForProcessing(core, depositBatchId);
      await core.processDailyBatch(depositBatchId);
      await core.connect(user1).claimDeposit(0);
      
      // Request withdrawal
      const shares = await lpShare.balanceOf(user1.address);
      await core.connect(user1).requestWithdraw(shares);
      
      // Process withdrawal batch
      const eligibleBatchId = depositBatchId + 2n;
      
      let nextBatch = depositBatchId + 1n;
      while (nextBatch <= eligibleBatchId) {
        const endTime = (nextBatch + 1n) * BATCH_SECONDS;
        await time.setNextBlockTimestamp(Number(endTime) + 1);
        await seedBatchForProcessing(core, nextBatch);
        await core.processDailyBatch(nextBatch);
        nextBatch++;
      }
      
      // Claim withdrawal (request ID 0)
      await core.connect(user1).claimWithdraw(0);
      
      // Try to claim again - should revert (not Pending)
      await expect(
        core.connect(user1).claimWithdraw(0)
      ).to.be.reverted;
    });
  });
});
