import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockERC20 } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

// Phase 6: Helper for 6-decimal token amounts
// paymentToken is USDC6 (6 decimals), internal accounting uses WAD (18 decimals)
function usdc(amount: string | number): bigint {
  return ethers.parseUnits(String(amount), 6);
}

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
    // Phase 6: Use 6-decimal token as per WP v2 Sec 6.2 (paymentToken = USDC6)
    const payment = (await MockERC20.deploy(
      "MockVaultToken",
      "MVT",
      6
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
    await proxy.setMinSeedAmount(usdc("100")); // 6-decimal token amount
    await proxy.setWithdrawLag(0);
    await proxy.setWithdrawalLagBatches(1); // D_lag = 1 batch

    // Configure FeeWaterfall (required for processDailyBatch)
    // pdd = -0.2 (20% drawdown floor), rhoBS = 0
    // phi splits: LP=80%, BS=10%, TR=10%
    await proxy.setFeeWaterfallConfig(
      ethers.parseEther("-0.2"), // pdd (WAD ratio)
      0n, // rhoBS
      ethers.parseEther("0.8"), // phiLP (WAD ratio)
      ethers.parseEther("0.1"), // phiBS (WAD ratio)
      ethers.parseEther("0.1") // phiTR (WAD ratio)
    );

    // Mint and fund users with 6-decimal token amounts
    const fundAmount = usdc("100000");
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
    await proxy.connect(userA).seedVault(usdc("1000"));

    const currentBatchId = await proxy.getCurrentBatchId();
    const firstBatchId = currentBatchId + 1n;

    return { ...fixture, currentBatchId, firstBatchId };
  }

  // ============================================================
  // Request ID-based Deposit (requestDeposit)
  // ============================================================
  describe("requestDeposit", () => {
    it("creates deposit request with sequential ID", async () => {
      const { proxy, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const amount6 = usdc("100");
      const amountWad = ethers.parseEther("100"); // Event emits WAD
      const moduleAtProxy = module.attach(proxy.target);

      // First request should get ID 0
      await expect(proxy.connect(userB).requestDeposit(amount6))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(0n, userB.address, amountWad, firstBatchId); // eligibleBatchId = currentBatchId + 1
    });

    it("increments request ID for each new request", async () => {
      const { proxy, userA, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const moduleAtProxy = module.attach(proxy.target);
      const amount6 = usdc("50");
      const amountWad = ethers.parseEther("50"); // Event emits WAD

      // First request
      await expect(proxy.connect(userA).requestDeposit(amount6))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(0n, userA.address, amountWad, firstBatchId);

      // Second request
      await expect(proxy.connect(userB).requestDeposit(amount6))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(1n, userB.address, amountWad, firstBatchId);

      // Third request from same user
      await expect(proxy.connect(userA).requestDeposit(amount6))
        .to.emit(moduleAtProxy, "DepositRequestCreated")
        .withArgs(2n, userA.address, amountWad, firstBatchId);
    });

    it("transfers tokens to vault", async () => {
      const { proxy, userB, payment } = await loadFixture(
        deploySeededVaultFixture
      );

      // Token transfer is in 6 decimals
      const amount6 = usdc("100");
      const balanceBefore = await payment.balanceOf(userB.address);

      await proxy.connect(userB).requestDeposit(amount6);

      const balanceAfter = await payment.balanceOf(userB.address);
      expect(balanceBefore - balanceAfter).to.equal(amount6);
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
        proxy.connect(userB).requestDeposit(usdc("100"))
      ).to.be.revertedWithCustomError(module, "VaultNotSeeded");
    });
  });

  // ============================================================
  // Request ID-based Withdraw (requestWithdraw)
  // ============================================================
  describe("requestWithdraw", () => {
    it("creates withdraw request with sequential ID", async () => {
      const { proxy, userA, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const shares = ethers.parseEther("100");
      const moduleAtProxy = module.attach(proxy.target);

      // D_lag = 1, so eligibleBatchId = currentBatchId + 1 + 1 = firstBatchId + 1
      await expect(proxy.connect(userA).requestWithdraw(shares))
        .to.emit(moduleAtProxy, "WithdrawRequestCreated")
        .withArgs(0n, userA.address, shares, firstBatchId + 1n);
    });

    it("applies D_lag to eligibleBatchId", async () => {
      const { proxy, userA, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 3 batches
      await proxy.setWithdrawalLagBatches(3);

      const shares = ethers.parseEther("50");
      const moduleAtProxy = module.attach(proxy.target);

      // eligibleBatchId = currentBatchId + 1 + D_lag(3) = firstBatchId + 3
      await expect(proxy.connect(userA).requestWithdraw(shares))
        .to.emit(moduleAtProxy, "WithdrawRequestCreated")
        .withArgs(0n, userA.address, shares, firstBatchId + 3n);
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

      const amount6 = usdc("200");
      const amountWad = ethers.parseEther("200"); // Event emits WAD
      await proxy.connect(userB).requestDeposit(amount6);

      const balanceBefore = await payment.balanceOf(userB.address);
      const moduleAtProxy = module.attach(proxy.target);

      // Event emits WAD amount
      await expect(proxy.connect(userB).cancelDeposit(0n))
        .to.emit(moduleAtProxy, "DepositRequestCancelled")
        .withArgs(0n, userB.address, amountWad);

      // Token refund is in 6 decimals
      const balanceAfter = await payment.balanceOf(userB.address);
      expect(balanceAfter - balanceBefore).to.equal(amount6);
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

      await proxy.connect(userA).requestDeposit(usdc("100"));

      await expect(
        proxy.connect(userB).cancelDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotOwned");
    });

    it("reverts if already processed", async () => {
      const { proxy, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Create request
      await proxy.connect(userB).requestDeposit(usdc("100"));

      // Process the batch
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

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
      const { proxy, userA, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Multiple deposit requests
      await proxy.connect(userA).requestDeposit(usdc("100"));
      await proxy.connect(userB).requestDeposit(usdc("200"));

      // Record P&L for batch 1
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);

      const moduleAtProxy = module.attach(proxy.target);

      // Process batch - should emit DailyBatchProcessed event
      await expect(proxy.processDailyBatch(firstBatchId)).to.emit(
        moduleAtProxy,
        "DailyBatchProcessed"
      );

      // Verify NAV increased by total deposits (300)
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1300"));
    });

    it("updates NAV and shares correctly", async () => {
      const { proxy, userB, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(usdc("500"));
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      // N = 1000 + 500 = 1500
      // S = 1000 + 500/1.0 = 1500
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1500"));
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("1500"));
    });

    it("reverts if batch ID is out of sequence", async () => {
      const { proxy, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(usdc("100"));

      // Try to process far-future batch when expecting firstBatchId
      await expect(
        proxy.processDailyBatch(firstBatchId + 4n)
      ).to.be.revertedWithCustomError(module, "BatchNotReady");
    });

    it("handles batch with only withdrawals", async () => {
      const { proxy, userA, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 0 for immediate withdrawal
      await proxy.setWithdrawalLagBatches(0);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("200"));
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);

      const moduleAtProxy = module.attach(proxy.target);

      await expect(proxy.processDailyBatch(firstBatchId)).to.emit(
        moduleAtProxy,
        "DailyBatchProcessed"
      );

      // N = 1000 - 200 = 800
      // S = 1000 - 200 = 800
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("800"));
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("800"));
    });

    it("handles mixed deposits and withdrawals", async () => {
      const { proxy, userA, userB, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 0 for immediate withdrawal
      await proxy.setWithdrawalLagBatches(0);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("300"));
      await proxy.connect(userB).requestDeposit(usdc("500"));

      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

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
      const { proxy, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Deposit in 6-decimal token, but stored internally as WAD
      const depositAmount6 = usdc("100");
      const depositAmountWad = ethers.parseEther("100"); // Expected internal WAD value
      await proxy.connect(userB).requestDeposit(depositAmount6);

      // Record positive P&L so price changes
      // N_pre = 1000 + 100 (P&L) = 1100, S = 1000
      // P_e = 1.1
      await proxy.recordDailyPnl(firstBatchId, ethers.parseEther("100"), 0n);
      await proxy.processDailyBatch(firstBatchId);

      const moduleAtProxy = module.attach(proxy.target);

      // shares = 100 / 1.1 ≈ 90.909...
      const expectedShares =
        (depositAmountWad * WAD) / ethers.parseEther("1.1");

      // Event signature: DepositClaimed(requestId, owner, amount, shares)
      // amount is emitted as WAD (internal storage)
      await expect(proxy.connect(userB).claimDeposit(0n))
        .to.emit(moduleAtProxy, "DepositClaimed")
        .withArgs(0n, userB.address, depositAmountWad, expectedShares);
    });

    it("reverts if batch not processed", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(usdc("100"));

      // Don't process the batch - claim should fail
      await expect(
        proxy.connect(userB).claimDeposit(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");
    });

    it("reverts if already claimed", async () => {
      const { proxy, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(usdc("100"));
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      // First claim succeeds
      await proxy.connect(userB).claimDeposit(0n);

      // Second claim fails - status is now Claimed, not Pending
      await expect(
        proxy.connect(userB).claimDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotPending");
    });

    it("reverts if not owner", async () => {
      const { proxy, userA, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(usdc("100"));
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

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
      const { proxy, userA, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 0
      await proxy.setWithdrawalLagBatches(0);

      const withdrawShares = ethers.parseEther("100");
      await proxy.connect(userA).requestWithdraw(withdrawShares);

      // Process with positive P&L
      // N_pre = 1000 + 200 = 1200, S = 1000
      // P_e = 1.2
      await proxy.recordDailyPnl(firstBatchId, ethers.parseEther("200"), 0n);
      await proxy.processDailyBatch(firstBatchId);

      const moduleAtProxy = module.attach(proxy.target);

      // payout = 100 * 1.2 = 120
      const expectedPayout = (withdrawShares * ethers.parseEther("1.2")) / WAD;

      // Event signature: WithdrawClaimed(requestId, owner, shares, assets)
      await expect(proxy.connect(userA).claimWithdraw(0n))
        .to.emit(moduleAtProxy, "WithdrawClaimed")
        .withArgs(0n, userA.address, withdrawShares, expectedPayout);
    });

    it("reverts if withdraw batch not yet processed", async () => {
      const { proxy, userA, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // D_lag = 1, so request at batch N is eligible at batch N + 2
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      // Process first batch (N+1)
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      // Batch 2 not yet processed, claim should fail
      await expect(
        proxy.connect(userA).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");
    });

    it("allows claim after D_lag batches processed", async () => {
      const { proxy, userA, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // D_lag = 1, request eligible at batch (firstBatchId + 1)
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      // Process first batch
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      // Process second batch
      const secondBatchId = firstBatchId + 1n;
      await proxy.recordDailyPnl(secondBatchId, 0n, 0n);
      await proxy.processDailyBatch(secondBatchId);

      const moduleAtProxy = module.attach(proxy.target);

      // Now claim should work
      // Event signature: WithdrawClaimed(requestId, owner, shares, assets)
      await expect(proxy.connect(userA).claimWithdraw(0n))
        .to.emit(moduleAtProxy, "WithdrawClaimed")
        .withArgs(
          0n,
          userA.address,
          ethers.parseEther("100"),
          ethers.parseEther("100")
        );
    });
  });

  // ============================================================
  // O(1) aggregation invariant
  // ============================================================
  describe("O(1) aggregation invariant", () => {
    it("pre-aggregated totals match individual requests sum", async () => {
      const { proxy, userA, userB, userC, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Multiple deposit requests (6-decimal token amounts)
      const amounts6 = [usdc("123"), usdc("456"), usdc("789")];
      // Expected WAD values (internal accounting)
      const amountsWad = [
        ethers.parseEther("123"),
        ethers.parseEther("456"),
        ethers.parseEther("789"),
      ];

      await proxy.connect(userA).requestDeposit(amounts6[0]);
      await proxy.connect(userB).requestDeposit(amounts6[1]);
      await proxy.connect(userC).requestDeposit(amounts6[2]);

      // The batch processing uses pre-aggregated total
      // which should equal sum of individual amounts (in WAD)
      const expectedTotalWad = amountsWad[0] + amountsWad[1] + amountsWad[2];

      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      // Verify NAV increased by total deposits (NAV is WAD)
      expect(await proxy.getVaultNav()).to.equal(
        ethers.parseEther("1000") + expectedTotalWad
      );
    });

    it("cancel updates pre-aggregated total correctly", async () => {
      const { proxy, userA, userB, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(usdc("100"));
      await proxy.connect(userB).requestDeposit(usdc("200"));

      // userA cancels
      await proxy.connect(userA).cancelDeposit(0n);

      // Process batch - should only include userB's 200
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1200"));
    });
  });

  // ============================================================
  // Multi-batch D_lag scenario
  // ============================================================
  describe("Multi-batch D_lag scenario", () => {
    it("enforces D_lag across multiple batches", async () => {
      const { proxy, userA, userB, module, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Set D_lag = 2 batches
      await proxy.setWithdrawalLagBatches(2);

      // userA requests withdraw (eligible at batch firstBatchId + 2)
      // Withdraw request ID = 0 (separate sequence from deposits)
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      // userB deposits (eligible at firstBatchId)
      // Deposit request ID = 0 (separate sequence from withdraws)
      await proxy.connect(userB).requestDeposit(usdc("200"));

      // Process first batch - deposit included in batch totals
      await proxy.recordDailyPnl(firstBatchId, 0n, 0n);
      await proxy.processDailyBatch(firstBatchId);

      // Deposit claimable (deposit request ID = 0)
      await proxy.connect(userB).claimDeposit(0n);

      // Withdraw NOT claimable yet (batch 3 not processed)
      // Withdraw request ID = 0
      await expect(
        proxy.connect(userA).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");

      // Process second batch
      const secondBatchId = firstBatchId + 1n;
      await proxy.recordDailyPnl(secondBatchId, 0n, 0n);
      await proxy.processDailyBatch(secondBatchId);

      // Still not claimable
      await expect(
        proxy.connect(userA).claimWithdraw(0n)
      ).to.be.revertedWithCustomError(module, "BatchNotProcessed");

      // Process third batch
      const thirdBatchId = firstBatchId + 2n;
      await proxy.recordDailyPnl(thirdBatchId, 0n, 0n);
      await proxy.processDailyBatch(thirdBatchId);

      // NOW claimable
      const moduleAtProxy = module.attach(proxy.target);
      await expect(proxy.connect(userA).claimWithdraw(0n)).to.emit(
        moduleAtProxy,
        "WithdrawClaimed"
      );
    });
  });
});
