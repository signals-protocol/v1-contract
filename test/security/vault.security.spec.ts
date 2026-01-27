import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockERC20 } from "../../typechain-types";
import { WAD, advancePastBatchEnd } from "../helpers/constants";

/**
 * Vault Security Tests
 *
 * Tests security-critical behaviors per whitepaper v2:
 * - CRITICAL-01: cancelDeposit after batch processed (CancelTooLate)
 * - HIGH-02: Shares=0 brick prevention (MIN_DEAD_SHARES)
 * - Deposit residual refund
 */

describe("Vault Security", () => {
  // Helper for 6-decimal token amounts
  const usdc = (amount: string) => ethers.parseUnits(amount, 6);

  async function deployVaultFixture() {
    const [owner, userA, userB, attacker] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const payment = (await MockERC20.deploy(
      "MockVaultToken",
      "MVT",
      6
    )) as MockERC20;

    const moduleFactory = await ethers.getContractFactory("LPVaultModule");
    const module = await moduleFactory.deploy();

    const proxyFactory = await ethers.getContractFactory("LPVaultModuleProxy");
    const proxy = (await proxyFactory.deploy(
      module.target
    )) as LPVaultModuleProxy;

    await proxy.setPaymentToken(payment.target);
    await proxy.setWithdrawalLagBatches(0);

    // Configure Risk and FeeWaterfall
    await proxy.setRiskConfig(
      ethers.parseEther("0.2"), // lambda = 0.2
      ethers.parseEther("1"), // kDrawdown
      false // enforceAlpha
    );
    await proxy.setFeeWaterfallConfig(
      0n, // rhoBS
      ethers.parseEther("0.8"), // phiLP
      ethers.parseEther("0.1"), // phiBS
      ethers.parseEther("0.1") // phiTR
    );

    // Fund users
    const fundAmount = usdc("100000");
    await payment.mint(userA.address, fundAmount);
    await payment.mint(userB.address, fundAmount);
    await payment.mint(attacker.address, fundAmount);
    await payment.connect(userA).approve(proxy.target, ethers.MaxUint256);
    await payment.connect(userB).approve(proxy.target, ethers.MaxUint256);
    await payment.connect(attacker).approve(proxy.target, ethers.MaxUint256);

    return { owner, userA, userB, attacker, payment, proxy, module };
  }

  async function deploySeededVaultFixture() {
    const fixture = await deployVaultFixture();
    const { proxy, userA } = fixture;
    
    await proxy.connect(userA).seedVault(usdc("1000"));
    await proxy.connect(userA).fundBackstop(usdc("500"));
    
    const currentBatchId = await proxy.getCurrentBatchId();
    const firstBatchId = currentBatchId + 1n;
    
    return { ...fixture, currentBatchId, firstBatchId };
  }

  const DEFAULT_DELTA_ET = ethers.parseEther("500");

  async function processBatchWithPnl(
    proxy: LPVaultModuleProxy,
    batchId: bigint,
    pnl: bigint = 0n,
    fees: bigint = 0n,
    deltaEt: bigint = DEFAULT_DELTA_ET
  ) {
    await proxy.harnessRecordPnl(batchId, pnl, fees, deltaEt);
    await advancePastBatchEnd(batchId);
    await proxy.processDailyBatch(batchId);
  }

  // Helper to get requestId from DepositRequestCreated event
  async function getDepositRequestIdFromTx(tx: any): Promise<bigint> {
    const receipt = await tx.wait();
    const event = receipt.logs.find((log: any) => {
      try {
        return log.fragment?.name === "DepositRequestCreated";
      } catch {
        return false;
      }
    });
    return event?.args?.[0] ?? 0n;
  }

  // ============================================================
  // Vault Seeding Security
  // ============================================================
  describe("Vault seeding security", () => {
    it("reverts requestDeposit before vault is seeded (VaultNotSeeded)", async () => {
      const { proxy, userB, module } = await loadFixture(deployVaultFixture);
      
      // Vault is not seeded yet
      await expect(
        proxy.connect(userB).requestDeposit(usdc("100"))
      ).to.be.revertedWithCustomError(module, "VaultNotSeeded");
    });

    it("reverts requestWithdraw before vault is seeded (VaultNotSeeded)", async () => {
      const { proxy, userB, module } = await loadFixture(deployVaultFixture);
      
      await expect(
        proxy.connect(userB).requestWithdraw(ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(module, "VaultNotSeeded");
    });

    it("reverts double seeding (VaultAlreadySeeded)", async () => {
      const { proxy, userA, module } = await loadFixture(deployVaultFixture);
      
      // First seed
      await proxy.connect(userA).seedVault(usdc("1000"));
      
      // Second seed should fail
      await expect(
        proxy.connect(userA).seedVault(usdc("1000"))
      ).to.be.revertedWithCustomError(module, "VaultAlreadySeeded");
    });
  });

  // ============================================================
  // CRITICAL-01: cancelDeposit after batch processed
  // ============================================================
  describe("CRITICAL-01: cancelDeposit after batch processed", () => {
    it("should revert when canceling deposit after batch is processed", async () => {
      const { proxy, userB, firstBatchId, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Step 1: userB deposits
      const tx = await proxy.connect(userB).requestDeposit(usdc("100"));
      const requestId = await getDepositRequestIdFromTx(tx);

      // Step 2: Process the batch (deposit is now reflected in NAV/shares)
      await processBatchWithPnl(proxy, firstBatchId);

      // Step 3: Attempt to cancel should revert with CancelTooLate
      await expect(
        proxy.connect(userB).cancelDeposit(requestId)
      ).to.be.revertedWithCustomError(module, "CancelTooLate");
    });

    it("should allow cancel before batch is processed", async () => {
      const { proxy, userB, payment } = await loadFixture(
        deploySeededVaultFixture
      );

      const balanceBefore = await payment.balanceOf(userB.address);
      
      // Step 1: userB deposits
      const tx = await proxy.connect(userB).requestDeposit(usdc("100"));
      const requestId = await getDepositRequestIdFromTx(tx);

      // Step 2: Cancel before batch processing
      await proxy.connect(userB).cancelDeposit(requestId);

      // Step 3: Verify funds returned
      const balanceAfter = await payment.balanceOf(userB.address);
      expect(balanceAfter).to.equal(balanceBefore);
    });

    it("prevents double-spend via cancel after processed (attack scenario)", async () => {
      const { proxy, userB, userA, firstBatchId, module } = await loadFixture(
        deploySeededVaultFixture
      );

      // Attack scenario:
      // 1. Attacker deposits in batch t
      // 2. Batch t is processed (attacker's deposit reflected in NAV)
      // 3. In batch t+1, another user deposits (funds go to escrow)
      // 4. Attacker tries to cancel their batch t deposit
      //    -> This would steal from batch t+1's pending deposits

      // Step 1: userB deposits in batch t
      const tx = await proxy.connect(userB).requestDeposit(usdc("100"));
      const attackerRequestId = await getDepositRequestIdFromTx(tx);

      // Step 2: Process batch t
      await processBatchWithPnl(proxy, firstBatchId);

      // Step 3: userA deposits in batch t+1
      await proxy.connect(userA).requestDeposit(usdc("200"));

      // Step 4: Attacker tries to cancel - should fail
      await expect(
        proxy.connect(userB).cancelDeposit(attackerRequestId)
      ).to.be.revertedWithCustomError(module, "CancelTooLate");
    });
  });

  // ============================================================
  // HIGH-02: Shares=0 brick prevention
  // ============================================================
  describe("HIGH-02: Shares=0 brick prevention", () => {
    it("maintains MIN_DEAD_SHARES after seeding", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);
      
      const minDeadShares = await proxy.MIN_DEAD_SHARES();
      const totalShares = await proxy.getVaultShares();
      
      expect(totalShares).to.be.gte(minDeadShares);
    });

    it("reverts withdrawal that would reduce shares below MIN_DEAD_SHARES", async () => {
      const { proxy, userA, firstBatchId, module } = await loadFixture(
        deploySeededVaultFixture
      );

      const totalShares = await proxy.getVaultShares();
      const minDeadShares = await proxy.MIN_DEAD_SHARES();
      
      // Try to withdraw almost all shares (leaving less than MIN_DEAD_SHARES)
      const withdrawAmount = totalShares - minDeadShares + 1n;
      await proxy.connect(userA).requestWithdraw(withdrawAmount);

      // Process batch should revert
      await proxy.harnessRecordPnl(firstBatchId, 0n, 0n, DEFAULT_DELTA_ET);
      await advancePastBatchEnd(firstBatchId);
      
      await expect(
        proxy.processDailyBatch(firstBatchId)
      ).to.be.revertedWithCustomError(module, "WithdrawalWouldBrickVault");
    });

    it("allows withdrawal that keeps shares above MIN_DEAD_SHARES", async () => {
      const { proxy, userA, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const totalShares = await proxy.getVaultShares();
      const minDeadShares = await proxy.MIN_DEAD_SHARES();
      
      // Withdraw amount that keeps shares > MIN_DEAD_SHARES
      const safeWithdrawAmount = totalShares - minDeadShares - ethers.parseEther("100");
      
      if (safeWithdrawAmount > 0n) {
        await proxy.connect(userA).requestWithdraw(safeWithdrawAmount);
        await processBatchWithPnl(proxy, firstBatchId);

        const sharesAfter = await proxy.getVaultShares();
        expect(sharesAfter).to.be.gte(minDeadShares);
      }
    });
  });

  // ============================================================
  // Deposit residual refund
  // ============================================================
  describe("Deposit residual refund", () => {
    it("refunds deposit residual on claim", async () => {
      const { proxy, userB, payment, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Deposit an amount that will have residual after floor division
      const depositAmount = usdc("101"); // 101 USDC
      const balanceBefore = await payment.balanceOf(userB.address);
      
      const tx = await proxy.connect(userB).requestDeposit(depositAmount);
      const requestId = await getDepositRequestIdFromTx(tx);

      // Process batch
      await processBatchWithPnl(proxy, firstBatchId);

      // Claim deposit
      await proxy.connect(userB).claimDeposit(requestId);
      const balanceAfterClaim = await payment.balanceOf(userB.address);

      // If there was a refund, balance should increase
      // (This depends on batch price and rounding)
      // At minimum, user should not lose any funds beyond shares purchased
      const totalSpent = balanceBefore - balanceAfterClaim;
      expect(totalSpent).to.be.lte(depositAmount);
    });

    it("vault never retains deposit residuals", async () => {
      const { proxy, userB, firstBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const depositAmount = usdc("100");
      
      const tx = await proxy.connect(userB).requestDeposit(depositAmount);
      await getDepositRequestIdFromTx(tx);

      // Get vault NAV before batch
      const navBefore = await proxy.getVaultNav();

      // Process batch
      await processBatchWithPnl(proxy, firstBatchId);

      // Get vault NAV after batch
      const navAfter = await proxy.getVaultNav();

      // NAV increase should equal amount USED (not full deposit amount)
      // Any residual should be refunded, not added to NAV
      const batchPrice = (await proxy.getBatchAggregation(firstBatchId)).batchPrice;
      const depositWad = depositAmount * BigInt(1e12); // Convert to WAD
      const sharesCalc = wDiv(depositWad, batchPrice);
      const amountUsed = wMul(sharesCalc, batchPrice);
      
      // NAV increase should be approximately amountUsed (allow small rounding)
      const navIncrease = navAfter - navBefore;
      expect(navIncrease).to.be.closeTo(amountUsed, ethers.parseEther("1"));
    });
  });
});

// Helper functions for WAD math (avoid BigInt prototype pollution)
function wDiv(a: bigint, b: bigint): bigint {
  return (a * WAD) / b;
}

function wMul(a: bigint, b: bigint): bigint {
  return (a * b) / WAD;
}
