import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockERC20 } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

/**
 * LPVaultModule Tests
 *
 * Tests the LP Vault operations in delegatecall environment.
 * - Request ID-based deposit/withdraw queue
 * - O(1) batch processing
 * - Claims
 *
 * Reference: whitepaper Section 3, plan.md Phase 6
 */

describe("LPVaultModule", () => {
  async function deployVaultFixture() {
    const [owner, userA, userB, userC] = await ethers.getSigners();

    // Deploy mock 18-decimal payment token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const payment = (await MockERC20.deploy(
      "MockVaultToken",
      "MVT",
      18
    )) as MockERC20;

    // Deploy LPVaultModule
    const moduleFactory = await ethers.getContractFactory("LPVaultModule");
    const module = await moduleFactory.deploy();

    // Deploy proxy
    const proxyFactory = await ethers.getContractFactory("LPVaultModuleProxy");
    const proxy = (await proxyFactory.deploy(
      module.target
    )) as LPVaultModuleProxy;

    // Configure proxy
    await proxy.setPaymentToken(payment.target);
    await proxy.setMinSeedAmount(ethers.parseEther("100"));
    await proxy.setWithdrawLag(0);
    await proxy.setWithdrawalLagBatches(1); // D_lag = 1 batch

    // Configure FeeWaterfall (required for processDailyBatch)
    // pdd = -0.2 (20% drawdown floor), rhoBS = 0
    // phi splits: LP=80%, BS=10%, TR=10%
    await proxy.setFeeWaterfallConfig(
      ethers.parseEther("-0.2"), // pdd
      0n, // rhoBS
      ethers.parseEther("0.8"), // phiLP
      ethers.parseEther("0.1"), // phiBS
      ethers.parseEther("0.1") // phiTR
    );

    // Mint and fund users
    const fundAmount = ethers.parseEther("100000");
    await payment.mint(userA.address, fundAmount);
    await payment.mint(userB.address, fundAmount);
    await payment.mint(userC.address, fundAmount);
    await payment.connect(userA).approve(proxy.target, ethers.MaxUint256);
    await payment.connect(userB).approve(proxy.target, ethers.MaxUint256);
    await payment.connect(userC).approve(proxy.target, ethers.MaxUint256);

    return { owner, userA, userB, userC, payment, proxy, module };
  }

  async function deploySeededVaultFixture() {
    const fixture = await deployVaultFixture();
    const { proxy, userA } = fixture;

    // Seed vault with 1000 tokens
    await proxy.connect(userA).seedVault(ethers.parseEther("1000"));

    return fixture;
  }

  // ============================================================
  // Request ID-based Deposit (requestDeposit)
  // ============================================================
  describe("requestDeposit", () => {
    it("creates deposit request with sequential ID", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const amount = ethers.parseEther("100");
      const moduleAtProxy = module.attach(proxy.target);

      // First request should get ID 0
      await expect(proxy.connect(userB).requestDeposit(amount))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(0n, userB.address, amount, 1n); // requestId=0, eligibleBatchId=1 (currentBatchId+1)
    });

    it("increments request ID for each new request", async () => {
      const { proxy, userA, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const moduleAtProxy = module.attach(proxy.target);
      const amount = ethers.parseEther("50");

      // First request
      await expect(proxy.connect(userA).requestDeposit(amount))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(0n, userA.address, amount, 1n);

      // Second request
      await expect(proxy.connect(userB).requestDeposit(amount))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(1n, userB.address, amount, 1n);

      // Third request from same user
      await expect(proxy.connect(userA).requestDeposit(amount))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(2n, userA.address, amount, 1n);
    });

    it("transfers tokens to vault", async () => {
      const { proxy, userB, payment } = await loadFixture(
        deploySeededVaultFixture
      );

      const amount = ethers.parseEther("100");
      const balanceBefore = await payment.balanceOf(userB.address);

      await proxy.connect(userB).requestDeposit(amount);

      const balanceAfter = await payment.balanceOf(userB.address);
      expect(balanceBefore - balanceAfter).to.equal(amount);
    });

    it("reverts on zero amount", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await expect(
        proxy.connect(userB).requestDeposit(0n)
      ).to.be.revertedWithCustomError(module, "ZeroAmount");
    });

    it("reverts if vault not seeded", async () => {
      const { proxy, userB, module } = await loadFixture(deployVaultFixture);

      await expect(
        proxy.connect(userB).requestDeposit(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(module, "VaultNotSeeded");
    });
  });

  // ============================================================
  // Request ID-based Withdraw (requestWithdraw)
  // ============================================================
  describe("requestWithdraw", () => {
    it("creates withdraw request with sequential ID", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const shares = ethers.parseEther("100");
      const moduleAtProxy = module.attach(proxy.target);

      // D_lag = 1, so eligibleBatchId = currentBatchId + 1 + 1 = 2
      await expect(proxy.connect(userA).requestWithdraw(shares))
        .to.emit(moduleAtProxy, "WithdrawRequestCreated")
        .withArgs(0n, userA.address, shares, 2n);
    });

    it("applies D_lag to eligibleBatchId", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 3 batches
      await proxy.setWithdrawalLagBatches(3);

      const shares = ethers.parseEther("50");
      const moduleAtProxy = module.attach(proxy.target);

      // eligibleBatchId = currentBatchId(0) + 1 + D_lag(3) = 4
      await expect(proxy.connect(userA).requestWithdraw(shares))
        .to.emit(moduleAtProxy, "WithdrawRequestCreated")
        .withArgs(0n, userA.address, shares, 4n);
    });

    it("reverts on zero shares", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await expect(
        proxy.connect(userA).requestWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "ZeroAmount");
    });
  });

  // ============================================================
  // Cancel Deposit V2
  // ============================================================
  describe("cancelDeposit", () => {
    it("cancels pending deposit and refunds tokens", async () => {
      const { proxy, userB, payment, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const amount = ethers.parseEther("200");
      await proxy.connect(userB).requestDeposit(amount);

      const balanceBefore = await payment.balanceOf(userB.address);
      const moduleAtProxy = module.attach(proxy.target);

      await expect(proxy.connect(userB).cancelDeposit(0n))
        .to.emit(moduleAtProxy, "DepositRequestCancelled")
        .withArgs(0n, userB.address, amount);

      const balanceAfter = await payment.balanceOf(userB.address);
      expect(balanceAfter - balanceBefore).to.equal(amount);
    });

    it("reverts if request not found", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await expect(
        proxy.connect(userB).cancelDeposit(999n)
      ).to.be.revertedWithCustomError(module, "RequestNotFound");
    });

    it("reverts if not owner", async () => {
      const { proxy, userA, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(ethers.parseEther("100"));

      await expect(
        proxy.connect(userB).cancelDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotOwned");
    });

    it("reverts if already processed", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Create request
      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));

      // Process the batch
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // Claim first to change status from Pending to Claimed
      await proxy.connect(userB).claimDeposit(0n);

      // Try to cancel claimed request - should fail with RequestNotPending
      await expect(
        proxy.connect(userB).cancelDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotPending");
    });
  });

  // ============================================================
  // Cancel Withdraw V2
  // ============================================================
  describe("cancelWithdraw", () => {
    it("cancels pending withdraw", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const shares = ethers.parseEther("100");
      await proxy.connect(userA).requestWithdraw(shares);

      const moduleAtProxy = module.attach(proxy.target);

      await expect(proxy.connect(userA).cancelWithdraw(0n))
        .to.emit(moduleAtProxy, "WithdrawRequestCancelled")
        .withArgs(0n, userA.address, shares);
    });

    it("reverts if request not found", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await expect(
        proxy.connect(userA).cancelWithdraw(999n)
      ).to.be.revertedWithCustomError(module, "RequestNotFound");
    });

    it("reverts if not owner", async () => {
      const { proxy, userA, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      await expect(
        proxy.connect(userB).cancelWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotOwned");
    });
  });

  // ============================================================
  // processDailyBatch (O(1) aggregation)
  // ============================================================
  describe("processDailyBatch", () => {
    it("processes batch using pre-aggregated totals", async () => {
      const { proxy, userA, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Multiple deposit requests
      await proxy.connect(userA).requestDeposit(ethers.parseEther("100"));
      await proxy.connect(userB).requestDeposit(ethers.parseEther("200"));

      // Record P&L for batch 1
      await proxy.recordDailyPnl(1n, 0n, 0n);

      const moduleAtProxy = module.attach(proxy.target);

      // Process batch - should emit DailyBatchProcessed event
      await expect(proxy.processDailyBatch(1n))
        .to.emit(moduleAtProxy, "DailyBatchProcessed");

      // Verify NAV increased by total deposits (300)
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1300"));
    });

    it("updates NAV and shares correctly", async () => {
      const { proxy, userB } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userB).requestDeposit(ethers.parseEther("500"));
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // N = 1000 + 500 = 1500
      // S = 1000 + 500/1.0 = 1500
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1500"));
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("1500"));
    });

    it("reverts if batch ID is out of sequence", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));

      // Try to process batch 5 when currentBatchId is 0 (expecting batch 1)
      await expect(proxy.processDailyBatch(5n)).to.be.revertedWithCustomError(
        module,
        "BatchNotReady"
      );
    });

    it("handles batch with only withdrawals", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 0 for immediate withdrawal
      await proxy.setWithdrawalLagBatches(0);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("200"));
      await proxy.recordDailyPnl(1n, 0n, 0n);

      const moduleAtProxy = module.attach(proxy.target);

      await expect(proxy.processDailyBatch(1n))
        .to.emit(moduleAtProxy, "DailyBatchProcessed");

      // N = 1000 - 200 = 800
      // S = 1000 - 200 = 800
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("800"));
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("800"));
    });

    it("handles mixed deposits and withdrawals", async () => {
      const { proxy, userA, userB } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 0 for immediate withdrawal
      await proxy.setWithdrawalLagBatches(0);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("300"));
      await proxy.connect(userB).requestDeposit(ethers.parseEther("500"));

      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // Net: +500 - 300 = +200
      // N = 1000 + 200 = 1200
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1200"));
    });
  });

  // ============================================================
  // claimDeposit
  // ============================================================
  describe("claimDeposit", () => {
    it("calculates shares correctly using batch price", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const depositAmount = ethers.parseEther("100");
      await proxy.connect(userB).requestDeposit(depositAmount);

      // Record positive P&L so price changes
      // N_pre = 1000 + 100 (P&L) = 1100, S = 1000
      // P_e = 1.1
      await proxy.recordDailyPnl(1n, ethers.parseEther("100"), 0n);
      await proxy.processDailyBatch(1n);

      const moduleAtProxy = module.attach(proxy.target);

      // shares = 100 / 1.1 ≈ 90.909...
      const expectedShares =
        (depositAmount * WAD) / ethers.parseEther("1.1");

      // Event signature: DepositClaimed(requestId, owner, amount, shares)
      await expect(proxy.connect(userB).claimDeposit(0n))
        .to.emit(moduleAtProxy, "DepositClaimed")
        .withArgs(0n, userB.address, depositAmount, expectedShares);
    });

    it("reverts if batch not processed", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));

      // Don't process the batch - claim should fail
      await expect(
        proxy.connect(userB).claimDeposit(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");
    });

    it("reverts if already claimed", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // First claim succeeds
      await proxy.connect(userB).claimDeposit(0n);

      // Second claim fails - status is now Claimed, not Pending
      await expect(
        proxy.connect(userB).claimDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotPending");
    });

    it("reverts if not owner", async () => {
      const { proxy, userA, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      await expect(
        proxy.connect(userA).claimDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotOwned");
    });
  });

  // ============================================================
  // claimWithdraw
  // ============================================================
  describe("claimWithdraw", () => {
    it("calculates payout correctly using batch price", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 0
      await proxy.setWithdrawalLagBatches(0);

      const withdrawShares = ethers.parseEther("100");
      await proxy.connect(userA).requestWithdraw(withdrawShares);

      // Process with positive P&L
      // N_pre = 1000 + 200 = 1200, S = 1000
      // P_e = 1.2
      await proxy.recordDailyPnl(1n, ethers.parseEther("200"), 0n);
      await proxy.processDailyBatch(1n);

      const moduleAtProxy = module.attach(proxy.target);

      // payout = 100 * 1.2 = 120
      const expectedPayout =
        (withdrawShares * ethers.parseEther("1.2")) / WAD;

      // Event signature: WithdrawClaimed(requestId, owner, shares, assets)
      await expect(proxy.connect(userA).claimWithdraw(0n))
        .to.emit(moduleAtProxy, "WithdrawClaimed")
        .withArgs(0n, userA.address, withdrawShares, expectedPayout);
    });

    it("reverts if withdraw batch not yet processed", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // D_lag = 1, so request at batch 0 is eligible at batch 2
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      // Process batch 1
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // Batch 2 not yet processed, claim should fail
      await expect(
        proxy.connect(userA).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");
    });

    it("allows claim after D_lag batches processed", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // D_lag = 1, request eligible at batch 2
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      // Process batch 1
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // Process batch 2
      await proxy.recordDailyPnl(2n, 0n, 0n);
      await proxy.processDailyBatch(2n);

      const moduleAtProxy = module.attach(proxy.target);

      // Now claim should work
      // Event signature: WithdrawClaimed(requestId, owner, shares, assets)
      await expect(proxy.connect(userA).claimWithdraw(0n))
        .to.emit(moduleAtProxy, "WithdrawClaimed")
        .withArgs(0n, userA.address, ethers.parseEther("100"), ethers.parseEther("100"));
    });
  });

  // ============================================================
  // O(1) aggregation invariant
  // ============================================================
  describe("O(1) aggregation invariant", () => {
    it("pre-aggregated totals match individual requests sum", async () => {
      const { proxy, userA, userB, userC } = await loadFixture(
        deploySeededVaultFixture
      );

      // Multiple deposit requests
      const amounts = [
        ethers.parseEther("123"),
        ethers.parseEther("456"),
        ethers.parseEther("789"),
      ];

      await proxy.connect(userA).requestDeposit(amounts[0]);
      await proxy.connect(userB).requestDeposit(amounts[1]);
      await proxy.connect(userC).requestDeposit(amounts[2]);

      // The batch processing uses pre-aggregated total
      // which should equal sum of individual amounts
      const expectedTotal = amounts[0] + amounts[1] + amounts[2];

      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // Verify NAV increased by total deposits
      expect(await proxy.getVaultNav()).to.equal(
        ethers.parseEther("1000") + expectedTotal
      );
    });

    it("cancel updates pre-aggregated total correctly", async () => {
      const { proxy, userA, userB } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(ethers.parseEther("100"));
      await proxy.connect(userB).requestDeposit(ethers.parseEther("200"));

      // userA cancels
      await proxy.connect(userA).cancelDeposit(0n);

      // Process batch - should only include userB's 200
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1200"));
    });
  });

  // ============================================================
  // Multi-batch D_lag scenario
  // ============================================================
  describe("Multi-batch D_lag scenario", () => {
    it("enforces D_lag across multiple batches", async () => {
      const { proxy, userA, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 2 batches
      await proxy.setWithdrawalLagBatches(2);

      // Day 0: userA requests withdraw (eligible at batch 3)
      // eligibleBatchId = currentBatchId(0) + 1 + D_lag(2) = 3
      // Withdraw request ID = 0 (separate sequence from deposits)
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      // Day 0: userB deposits (eligible at batch 1)
      // Deposit request ID = 0 (separate sequence from withdraws)
      await proxy.connect(userB).requestDeposit(ethers.parseEther("200"));

      // Process batch 1 - deposit included in batch totals
      await proxy.recordDailyPnl(1n, 0n, 0n);
      await proxy.processDailyBatch(1n);

      // Deposit claimable (deposit request ID = 0)
      await proxy.connect(userB).claimDeposit(0n);

      // Withdraw NOT claimable yet (batch 3 not processed)
      // Withdraw request ID = 0
      await expect(
        proxy.connect(userA).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");

      // Process batch 2
      await proxy.recordDailyPnl(2n, 0n, 0n);
      await proxy.processDailyBatch(2n);

      // Still not claimable
      await expect(
        proxy.connect(userA).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");

      // Process batch 3
      await proxy.recordDailyPnl(3n, 0n, 0n);
      await proxy.processDailyBatch(3n);

      // NOW claimable
      const moduleAtProxy = module.attach(proxy.target);
      await expect(proxy.connect(userA).claimWithdraw(0n))
        .to.emit(moduleAtProxy, "WithdrawClaimed");
    });
  });
});
