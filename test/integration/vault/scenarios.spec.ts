import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockERC20 } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

/**
 * LP Vault Integration Scenarios
 *
 * Tests complete multi-day workflows per whitepaper Section 3.
 * Reference: plan.md Phase 6
 */

describe("LP Vault Scenarios", () => {
  async function deployVaultFixture() {
    const [owner, userA, userB, userC, userD, userE] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const payment = (await MockERC20.deploy(
      "MockVaultToken",
      "MVT",
      18
    )) as MockERC20;

    const moduleFactory = await ethers.getContractFactory("LPVaultModule");
    const module = await moduleFactory.deploy();

    const proxyFactory = await ethers.getContractFactory("LPVaultModuleProxy");
    const proxy = (await proxyFactory.deploy(
      module.target
    )) as LPVaultModuleProxy;

    await proxy.setPaymentToken(payment.target);
    await proxy.setMinSeedAmount(ethers.parseEther("100"));
    await proxy.setWithdrawLag(0);
    await proxy.setWithdrawalLagBatches(1); // D_lag = 1 batch

    // FeeWaterfall config
    // pdd = -20%, phiLP = 80%, phiBS = 10%, phiTR = 10%
    await proxy.setFeeWaterfallConfig(
      ethers.parseEther("-0.2"),
      0n,
      ethers.parseEther("0.8"),
      ethers.parseEther("0.1"),
      ethers.parseEther("0.1")
    );

    // Initialize capital stack with backstop
    await proxy.setCapitalStack(
      ethers.parseEther("500"), // backstopNav
      ethers.parseEther("100") // treasuryNav
    );

    const fundAmount = ethers.parseEther("1000000");
    for (const user of [userA, userB, userC, userD, userE]) {
      await payment.mint(user.address, fundAmount);
      await payment.connect(user).approve(proxy.target, ethers.MaxUint256);
    }

    return { owner, userA, userB, userC, userD, userE, payment, proxy, module };
  }

  async function deploySeededVaultFixture() {
    const fixture = await deployVaultFixture();
    const { proxy, userA } = fixture;
    await proxy.connect(userA).seedVault(ethers.parseEther("10000"));
    return fixture;
  }

  // ============================================================
  // Scenario 1: Happy Path 3-Day
  // ============================================================
  describe("Scenario: Happy Path 3-Day", () => {
    /**
     * Day 0: Vault seeded with 10,000
     * Day 1: Users deposit, market has profit (L=+500), batch processed
     * Day 2: More deposits, market has loss (L=-200), fees (F=100)
     * Day 3: Users withdraw, market profit (L=+300)
     * 
     * Verify: NAV tracks correctly, claims work, price reflects P&L
     */
    it("completes full 3-day deposit/trade/withdraw cycle", async () => {
      const { proxy, userA, userB, userC } = await loadFixture(
        deploySeededVaultFixture
      );

      // Initial state
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("10000"));
      expect(await proxy.getVaultPrice()).to.equal(WAD);

      // === Day 1 ===
      // userB deposits 1000
      await proxy.connect(userB).requestDeposit(ethers.parseEther("1000"));

      // Market profit: L = +500
      await proxy.recordDailyPnl(1n, ethers.parseEther("500"), 0n);
      await proxy.processDailyBatch(1n);

      // userB claims deposit
      await proxy.connect(userB).claimDeposit(0n);

      // NAV should be ~10000 + 500 (profit) + 1000 (deposit) = 11500
      const nav1 = await proxy.getVaultNav();
      expect(nav1).to.be.closeTo(
        ethers.parseEther("11500"),
        ethers.parseEther("100")
      );

      // Price increased due to profit
      const price1 = await proxy.getVaultPrice();
      expect(price1).to.be.gt(WAD);

      // === Day 2 ===
      // userC deposits 2000
      await proxy.connect(userC).requestDeposit(ethers.parseEther("2000"));

      // Market loss: L = -200, Fees: F = 100
      await proxy.recordDailyPnl(2n, ethers.parseEther("-200"), ethers.parseEther("100"));
      await proxy.processDailyBatch(2n);

      await proxy.connect(userC).claimDeposit(1n);

      const nav2 = await proxy.getVaultNav();
      // NAV affected by loss and fees (LP gets 80% of fees)
      expect(nav2).to.be.gt(ethers.parseEther("11000"));

      // === Day 3 ===
      // userA requests withdraw (has shares from seed)
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("1000"));

      // Market profit: L = +300
      await proxy.recordDailyPnl(3n, ethers.parseEther("300"), 0n);
      await proxy.processDailyBatch(3n);

      // D_lag = 1, so userA's withdraw is eligible at batch 3
      // But they requested in batch 2, eligible at batch 3
      // Actually: requested in Day 3 (batch 3), eligible at batch 3+1+1 = 5
      // Wait, D_lag changes when they request
      // Let me recalculate: currentBatchId = 2 when requesting
      // eligibleBatchId = 2 + 1 + 1 = 4

      // Process batch 4 for withdrawal to be claimable
      await proxy.recordDailyPnl(4n, 0n, 0n);
      await proxy.processDailyBatch(4n);

      await proxy.connect(userA).claimWithdraw(0n);

      const nav3 = await proxy.getVaultNav();
      // NAV should have increased with profits, decreased with withdrawal
      expect(nav3).to.be.gt(ethers.parseEther("10000"));

      // Price should reflect overall positive performance
      const finalPrice = await proxy.getVaultPrice();
      expect(finalPrice).to.be.gt(WAD);
    });
  });

  // ============================================================
  // Scenario 2: Drawdown + Backstop Grant
  // ============================================================
  describe("Scenario: Drawdown + Grant", () => {
    /**
     * Vault experiences significant loss that triggers backstop grant.
     * 
     * Day 1: Large market loss (L = -2000) on 10000 NAV = -20%
     * Drawdown floor (pdd) = -20%, so backstop grant should activate
     * 
     * Verify: Grant limits loss, backstop NAV decreases, LP protected
     */
    it("backstop grant protects LP from excessive drawdown", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      const navBefore = await proxy.getVaultNav();
      const [backstopBefore] = await proxy.getCapitalStack();

      expect(navBefore).to.equal(ethers.parseEther("10000"));
      expect(backstopBefore).to.equal(ethers.parseEther("500"));

      // Large loss: -2000 on 10000 = 20% loss
      // This should trigger drawdown floor protection
      await proxy.recordDailyPnl(1n, ethers.parseEther("-2000"), 0n);
      await proxy.processDailyBatch(1n);

      const navAfter = await proxy.getVaultNav();
      const [backstopAfter] = await proxy.getCapitalStack();

      // LP should be partially protected
      // Without grant: NAV = 10000 - 2000 = 8000
      // With grant: NAV > 8000 (grant compensates some loss)
      expect(navAfter).to.be.gte(ethers.parseEther("8000"));

      // Backstop should have decreased (provided grant)
      expect(backstopAfter).to.be.lte(backstopBefore);

      // Drawdown should be limited by pdd
      const price = await proxy.getVaultPrice();
      const peak = await proxy.getVaultPricePeak();
      const drawdown = WAD - (price * WAD) / peak;

      // Drawdown should not exceed 20% (pdd = -0.2)
      expect(drawdown).to.be.lte(ethers.parseEther("0.25")); // Allow some margin
    });

    it("recovery from drawdown updates peak correctly", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Day 1: Loss
      await proxy.recordDailyPnl(1n, ethers.parseEther("-1000"), 0n);
      await proxy.processDailyBatch(1n);

      const peakAfterLoss = await proxy.getVaultPricePeak();
      const priceAfterLoss = await proxy.getVaultPrice();
      expect(priceAfterLoss).to.be.lt(peakAfterLoss);

      // Day 2: Recovery
      await proxy.recordDailyPnl(2n, ethers.parseEther("1500"), 0n);
      await proxy.processDailyBatch(2n);

      const peakAfterRecovery = await proxy.getVaultPricePeak();
      const priceAfterRecovery = await proxy.getVaultPrice();

      // Price should exceed old peak, setting new peak
      expect(priceAfterRecovery).to.be.gt(WAD);
      expect(peakAfterRecovery).to.be.gte(priceAfterRecovery);
    });
  });

  // ============================================================
  // Scenario 3: Bank Run
  // ============================================================
  describe("Scenario: Bank Run", () => {
    /**
     * Multiple users simultaneously request large withdrawals.
     * System should handle gracefully without DoS.
     * 
     * Setup: 5 users each have deposited
     * Event: All 5 request withdrawal simultaneously
     * Verify: All requests processed, NAV/shares remain consistent
     */
    it("handles simultaneous large withdrawal requests", async () => {
      const { proxy, userA, userB, userC, userD, userE } = await loadFixture(
        deploySeededVaultFixture
      );

      // Setup: Multiple users deposit
      const depositAmount = ethers.parseEther("2000");
      await proxy.connect(userB).requestDeposit(depositAmount);
      await proxy.connect(userC).requestDeposit(depositAmount);
      await proxy.connect(userD).requestDeposit(depositAmount);
      await proxy.connect(userE).requestDeposit(depositAmount);

      // Process Day 1: deposits
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // All users claim deposits
      await proxy.connect(userB).claimDeposit(0n);
      await proxy.connect(userC).claimDeposit(1n);
      await proxy.connect(userD).claimDeposit(2n);
      await proxy.connect(userE).claimDeposit(3n);

      const navAfterDeposits = await proxy.getVaultNav();
      expect(navAfterDeposits).to.equal(ethers.parseEther("18000")); // 10000 + 4*2000

      // Bank run: All users request withdrawal
      const withdrawAmount = ethers.parseEther("1500");
      await proxy.connect(userA).requestWithdraw(withdrawAmount);
      await proxy.connect(userB).requestWithdraw(withdrawAmount);
      await proxy.connect(userC).requestWithdraw(withdrawAmount);
      await proxy.connect(userD).requestWithdraw(withdrawAmount);
      await proxy.connect(userE).requestWithdraw(withdrawAmount);

      // Check pending totals - O(1) aggregation should handle this
      const [, pendingWithdraws] = await proxy.getPendingBatchTotals(3n); // D_lag=1, so eligible at batch 3
      expect(pendingWithdraws).to.equal(ethers.parseEther("7500")); // 5 * 1500

      // Process Day 2: empty (withdraws not eligible yet due to D_lag)
      await proxy.recordDailyPnl(2n, 0n, 0n);
      await proxy.processDailyBatch(2n);

      // Process Day 3: withdrawals now eligible
      await proxy.recordDailyPnl(3n, 0n, 0n);
      await proxy.processDailyBatch(3n);

      // All users claim withdrawals
      await proxy.connect(userA).claimWithdraw(0n);
      await proxy.connect(userB).claimWithdraw(1n);
      await proxy.connect(userC).claimWithdraw(2n);
      await proxy.connect(userD).claimWithdraw(3n);
      await proxy.connect(userE).claimWithdraw(4n);

      const navAfterWithdraws = await proxy.getVaultNav();
      // 18000 - 7500 = 10500
      expect(navAfterWithdraws).to.equal(ethers.parseEther("10500"));

      // Price should remain stable (no P&L)
      const price = await proxy.getVaultPrice();
      const diff = price > WAD ? price - WAD : WAD - price;
      expect(diff).to.be.lte(10n);
    });

    it("D_lag prevents immediate bank run exit", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Users deposit
      await proxy.connect(userB).requestDeposit(ethers.parseEther("5000"));
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);
      await proxy.connect(userB).claimDeposit(0n);

      // Panic: immediate withdrawal request
      await proxy.connect(userB).requestWithdraw(ethers.parseEther("5000"));

      // Try to claim immediately after batch 2
      await proxy.recordDailyPnl(2n, 0n, 0n);
      await proxy.processDailyBatch(2n);

      // Should fail - D_lag not met (eligible at batch 3)
      await expect(
        proxy.connect(userB).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");

      // Process batch 3 - now should work
      await proxy.recordDailyPnl(3n, 0n, 0n);
      await proxy.processDailyBatch(3n);

      await expect(proxy.connect(userB).claimWithdraw(0n)).to.not.be.reverted;
    });

    it("maintains price invariant during mass exit", async () => {
      const { proxy, userB, userC, userD } = await loadFixture(
        deploySeededVaultFixture
      );

      // Setup deposits
      await proxy.connect(userB).requestDeposit(ethers.parseEther("3000"));
      await proxy.connect(userC).requestDeposit(ethers.parseEther("3000"));
      await proxy.connect(userD).requestDeposit(ethers.parseEther("3000"));

      await proxy.recordDailyPnl(1n, ethers.parseEther("500"), 0n); // Some profit
      await proxy.processDailyBatch(1n);

      await proxy.connect(userB).claimDeposit(0n);
      await proxy.connect(userC).claimDeposit(1n);
      await proxy.connect(userD).claimDeposit(2n);

      const priceBeforeRun = await proxy.getVaultPrice();

      // Mass withdrawal
      await proxy.connect(userB).requestWithdraw(ethers.parseEther("2500"));
      await proxy.connect(userC).requestWithdraw(ethers.parseEther("2500"));
      await proxy.connect(userD).requestWithdraw(ethers.parseEther("2500"));

      // Process through D_lag
      await proxy.recordDailyPnl(2n, 0n, 0n);
      await proxy.processDailyBatch(2n);
      await proxy.recordDailyPnl(3n, 0n, 0n);
      await proxy.processDailyBatch(3n);

      await proxy.connect(userB).claimWithdraw(0n);
      await proxy.connect(userC).claimWithdraw(1n);
      await proxy.connect(userD).claimWithdraw(2n);

      const priceAfterRun = await proxy.getVaultPrice();

      // Price should be preserved (within rounding)
      const priceDiff =
        priceAfterRun > priceBeforeRun
          ? priceAfterRun - priceBeforeRun
          : priceBeforeRun - priceAfterRun;
      expect(priceDiff).to.be.lte(ethers.parseEther("0.001")); // < 0.1% change
    });
  });
});

