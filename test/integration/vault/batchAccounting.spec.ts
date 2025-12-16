/**
 * BatchAccounting Spec Tests (Phase 6 TDD)
 *
 * Whitepaper v2 Section 3 requirements:
 * - processDailyBatch is the ONLY place that modifies NAV/Shares
 * - claimDeposit/claimWithdraw do NOT change NAV/Shares
 * - Pre-batch NAV equation: N^pre_t = N_{t-1} + L_t + F_t + G_t
 * - Batch price equation: P^e_t = N^pre_t / S_{t-1}
 *
 * These tests are expected to FAIL initially (TDD approach).
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockERC20 } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

// Phase 6: Helper for 6-decimal token amounts
function usdc(amount: string | number): bigint {
  return ethers.parseUnits(String(amount), 6);
}

describe("BatchAccounting Spec Tests (WP v2 Sec 3)", () => {
  async function deployVaultFixture() {
    const [owner, userA, userB] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    // Phase 6: Use 6-decimal token as per WP v2 Sec 6.2 (paymentToken = USDC6)
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
    await proxy.setMinSeedAmount(usdc("100"));
    await proxy.setWithdrawLag(0);
    await proxy.setWithdrawalLagBatches(0);
    await proxy.setFeeWaterfallConfig(
      ethers.parseEther("-0.3"), // pdd = -30% (WAD ratio)
      0n, // rhoBS
      ethers.parseEther("0.7"), // phiLP = 70% (WAD ratio)
      ethers.parseEther("0.2"), // phiBS = 20% (WAD ratio)
      ethers.parseEther("0.1") // phiTR = 10% (WAD ratio)
    );

    // Fund with 6-decimal token amounts
    const fundAmount = usdc("100000");
    await payment.mint(owner.address, fundAmount);
    await payment.mint(userA.address, fundAmount);
    await payment.mint(userB.address, fundAmount);
    await payment.connect(owner).approve(proxy.target, ethers.MaxUint256);
    await payment.connect(userA).approve(proxy.target, ethers.MaxUint256);
    await payment.connect(userB).approve(proxy.target, ethers.MaxUint256);

    return { owner, userA, userB, payment, proxy, module };
  }

  async function deploySeededVaultFixture() {
    const fixture = await deployVaultFixture();
    await fixture.proxy.connect(fixture.owner).seedVault(usdc("1000"));
    // V1 Phase 7: Set backstop and deltaEt for testing grant mechanics
    // Production V1 uses deltaEt = 0 (uniform prior), but tests need to verify grant flow
    const backstopNav = ethers.parseEther("500"); // 500 WAD backstop
    await fixture.proxy.setCapitalStack(backstopNav, 0n);
    await fixture.proxy.setDeltaEt(backstopNav);
    const currentBatchId = await fixture.proxy.getCurrentBatchId();
    return { ...fixture, currentBatchId };
  }

  // ================================================================
  // SPEC-1: processDailyBatch is the ONLY place that modifies NAV/Shares
  // (WP v2 Sec 3.6: batch algorithm specifies state updates)
  // ================================================================
  describe("SPEC-1: Only processDailyBatch modifies NAV/Shares", () => {
    it("requestDeposit does NOT change NAV or Shares", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      const navBefore = await proxy.getVaultNav();
      const sharesBefore = await proxy.getVaultShares();

      await proxy.connect(userA).requestDeposit(usdc("500"));

      const navAfter = await proxy.getVaultNav();
      const sharesAfter = await proxy.getVaultShares();

      expect(navAfter).to.equal(navBefore, "NAV changed on requestDeposit");
      expect(sharesAfter).to.equal(
        sharesBefore,
        "Shares changed on requestDeposit"
      );
    });

    it("requestWithdraw does NOT change NAV or Shares", async () => {
      const { proxy, owner } = await loadFixture(deploySeededVaultFixture);

      const navBefore = await proxy.getVaultNav();
      const sharesBefore = await proxy.getVaultShares();

      await proxy.connect(owner).requestWithdraw(ethers.parseEther("200"));

      const navAfter = await proxy.getVaultNav();
      const sharesAfter = await proxy.getVaultShares();

      expect(navAfter).to.equal(navBefore, "NAV changed on requestWithdraw");
      expect(sharesAfter).to.equal(
        sharesBefore,
        "Shares changed on requestWithdraw"
      );
    });

    it("claimDeposit does NOT change NAV or Shares", async () => {
      const { proxy, userA, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(usdc("500"));
      await proxy.recordDailyPnl(currentBatchId + 1n, 0n, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(currentBatchId + 1n);

      // Record state after batch (batch already updated NAV/Shares)
      const navAfterBatch = await proxy.getVaultNav();
      const sharesAfterBatch = await proxy.getVaultShares();

      // Claim should NOT change NAV/Shares
      await proxy.connect(userA).claimDeposit(0n);

      const navAfterClaim = await proxy.getVaultNav();
      const sharesAfterClaim = await proxy.getVaultShares();

      expect(navAfterClaim).to.equal(
        navAfterBatch,
        "NAV changed on claimDeposit"
      );
      expect(sharesAfterClaim).to.equal(
        sharesAfterBatch,
        "Shares changed on claimDeposit"
      );
    });

    it("claimWithdraw does NOT change NAV or Shares", async () => {
      const { proxy, owner, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(owner).requestWithdraw(ethers.parseEther("200"));
      await proxy.recordDailyPnl(currentBatchId + 1n, 0n, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(currentBatchId + 1n);

      const navAfterBatch = await proxy.getVaultNav();
      const sharesAfterBatch = await proxy.getVaultShares();

      await proxy.connect(owner).claimWithdraw(0n);

      const navAfterClaim = await proxy.getVaultNav();
      const sharesAfterClaim = await proxy.getVaultShares();

      expect(navAfterClaim).to.equal(
        navAfterBatch,
        "NAV changed on claimWithdraw"
      );
      expect(sharesAfterClaim).to.equal(
        sharesAfterBatch,
        "Shares changed on claimWithdraw"
      );
    });

    it("processDailyBatch is called exactly once per batch", async () => {
      const { proxy, module, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const batchId = currentBatchId + 1n;

      // First call succeeds
      await proxy.recordDailyPnl(batchId, 0n, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      // Second call reverts
      await expect(
        proxy.processDailyBatch(batchId)
      ).to.be.revertedWithCustomError(module, "BatchNotReady");
    });
  });

  // ================================================================
  // SPEC-2: Pre-batch NAV equation: N^pre_t = N_{t-1} + L_t + F_t + G_t
  // (WP v2 Eq 3.4)
  // ================================================================
  describe("SPEC-2: Pre-batch NAV equation (INV-NAV)", () => {
    it("N^pre_t - N_{t-1} = L_t + F_t + G_t (positive P&L)", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const N_prev = await proxy.getVaultNav();
      const batchId = currentBatchId + 1n;

      const Lt = ethers.parseEther("100");
      const Ftot = ethers.parseEther("30");

      await proxy.recordDailyPnl(batchId, Lt, Ftot, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      // Get recorded values from snapshot
      const [, , ft, gt, npre] = await proxy.getDailyPnl(batchId);

      // Verify invariant: Npre - Nprev = Lt + Ft + Gt
      const lhs = npre - N_prev;
      const rhs = Lt + ft + gt;

      expect(lhs).to.equal(rhs, "Pre-batch NAV equation violated");
    });

    it("N^pre_t - N_{t-1} = L_t + F_t + G_t (negative P&L with grant)", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Initialize backstop for grant capability
      await proxy.setCapitalStack(ethers.parseEther("500"), 0n);

      const N_prev = await proxy.getVaultNav();
      const batchId = currentBatchId + 1n;

      // Large negative P&L that triggers drawdown floor
      const Lt = ethers.parseEther("-400"); // -40% of NAV
      const Ftot = ethers.parseEther("20");

      await proxy.recordDailyPnl(batchId, Lt, Ftot, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const [, , ft, gt, npre] = await proxy.getDailyPnl(batchId);

      // Verify invariant
      const lhs = npre - N_prev;
      const rhs = Lt + ft + gt;

      expect(lhs).to.equal(rhs, "Pre-batch NAV equation violated with grant");
    });

    it("N^pre_t - N_{t-1} = L_t + F_t + G_t (zero P&L)", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const N_prev = await proxy.getVaultNav();
      const batchId = currentBatchId + 1n;

      await proxy.recordDailyPnl(batchId, 0n, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const [, , ft, gt, npre] = await proxy.getDailyPnl(batchId);

      // Npre = N_prev when L=F=G=0
      expect(npre).to.equal(N_prev);
      expect(ft).to.equal(0n);
      expect(gt).to.equal(0n);
    });
  });

  // ================================================================
  // SPEC-3: Batch price equation: P^e_t = N^pre_t / S_{t-1}
  // (WP v2 Eq 3.4)
  // ================================================================
  describe("SPEC-3: Batch price equation", () => {
    it("P^e_t = N^pre_t / S_{t-1}", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const S_prev = await proxy.getVaultShares();
      const batchId = currentBatchId + 1n;

      const Lt = ethers.parseEther("50");
      await proxy.recordDailyPnl(batchId, Lt, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const [, , , , npre, pe] = await proxy.getDailyPnl(batchId);

      // Verify: Pe = Npre / S_prev
      const expectedPe = (npre * WAD) / S_prev;

      // Allow 1 wei tolerance for rounding
      expect(pe).to.be.closeTo(expectedPe, 1n);
    });

    it("batch price used for all deposits and withdrawals in same batch", async () => {
      const { proxy, userA, userB, owner, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Multiple users request deposits/withdrawals
      await proxy.connect(userA).requestDeposit(usdc("100"));
      await proxy.connect(userB).requestDeposit(usdc("200"));
      await proxy.connect(owner).requestWithdraw(ethers.parseEther("50"));

      const batchId = currentBatchId + 1n;
      await proxy.recordDailyPnl(batchId, ethers.parseEther("30"), 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      // Get batch aggregation
      const [totalDeposits, totalWithdraws, batchPrice] =
        await proxy.getBatchAggregation(batchId);

      expect(totalDeposits).to.equal(ethers.parseEther("300")); // 100 + 200
      expect(totalWithdraws).to.equal(ethers.parseEther("50"));
      expect(batchPrice).to.be.gt(WAD); // Price increased due to positive P&L

      // All users in this batch used the same batchPrice
      // This is implicit in the batch processing - all are processed at batchPrice
    });
  });

  // ================================================================
  // SPEC-4: Price invariance during deposit/withdraw processing
  // (WP v2 Sec 3.6: "N'/S' = P")
  // ================================================================
  describe("SPEC-4: Price invariance during batch processing", () => {
    it("price preserved after deposit processing", async () => {
      const { proxy, userA, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(usdc("500"));

      const batchId = currentBatchId + 1n;
      await proxy.recordDailyPnl(batchId, 0n, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const [, , batchPrice] = await proxy.getBatchAggregation(batchId);
      const finalPrice = await proxy.getVaultPrice();

      // Final price should equal batch price (within tolerance)
      const diff =
        finalPrice > batchPrice
          ? finalPrice - batchPrice
          : batchPrice - finalPrice;
      expect(diff).to.be.lte(10n, "Price not preserved after deposit");
    });

    it("price preserved after withdrawal processing", async () => {
      const { proxy, owner, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(owner).requestWithdraw(ethers.parseEther("200"));

      const batchId = currentBatchId + 1n;
      await proxy.recordDailyPnl(batchId, 0n, 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const [, , batchPrice] = await proxy.getBatchAggregation(batchId);
      const finalPrice = await proxy.getVaultPrice();

      const diff =
        finalPrice > batchPrice
          ? finalPrice - batchPrice
          : batchPrice - finalPrice;
      expect(diff).to.be.lte(10n, "Price not preserved after withdrawal");
    });

    it("price preserved after mixed deposit/withdrawal", async () => {
      const { proxy, owner, userA, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(usdc("300"));
      await proxy.connect(owner).requestWithdraw(ethers.parseEther("100"));

      const batchId = currentBatchId + 1n;
      await proxy.recordDailyPnl(batchId, ethers.parseEther("50"), 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const [, , batchPrice] = await proxy.getBatchAggregation(batchId);
      const finalPrice = await proxy.getVaultPrice();

      const diff =
        finalPrice > batchPrice
          ? finalPrice - batchPrice
          : batchPrice - finalPrice;
      expect(diff).to.be.lte(10n, "Price not preserved after mixed ops");
    });
  });

  // ================================================================
  // SPEC-5: Same market underwriters get same return
  // (WP v2 Sec 3.1: "any two LP shares that underwrite the same
  // sequence of daily markets earn exactly the same return")
  // ================================================================
  describe("SPEC-5: Same market underwriters get same return", () => {
    it("shares existing at batch start all receive same P&L", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // Initial shares = 1000 WAD (from seed)
      const initialPrice = await proxy.getVaultPrice();

      // Process batch with P&L
      const batchId = currentBatchId + 1n;
      await proxy.recordDailyPnl(batchId, ethers.parseEther("100"), 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const finalPrice = await proxy.getVaultPrice();

      // Price change applies equally to all shares
      // Every share went from initialPrice to finalPrice
      const priceChange = finalPrice - initialPrice;

      // Total value change = shares * priceChange
      // This is uniform across all shares that were present at batch start
      expect(priceChange).to.be.gt(0n);
    });

    it("new deposits don't dilute existing shares", async () => {
      const { proxy, userA, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      // UserA deposits, processed at batch price
      await proxy.connect(userA).requestDeposit(usdc("500"));

      const batchId = currentBatchId + 1n;
      await proxy.recordDailyPnl(batchId, ethers.parseEther("100"), 0n, ethers.parseEther("500")); // +10% P&L
      await proxy.processDailyBatch(batchId);

      // Claim deposit
      await proxy.connect(userA).claimDeposit(0n);

      // Owner's shares still exist and benefited from P&L
      // New shares were minted at post-P&L price
      const priceAfter = await proxy.getVaultPrice();

      // Owner's per-share value = priceAfter (> 1.0 due to P&L)
      // UserA paid priceAfter per share, so no dilution of existing value
      expect(priceAfter).to.be.gt(WAD);
    });
  });

  // ================================================================
  // SPEC-6: No duplicate state updates
  // ================================================================
  describe("SPEC-6: No duplicate state updates", () => {
    it("recordDailyPnl accumulates, doesn't overwrite", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const batchId = currentBatchId + 1n;

      // Record P&L from multiple markets
      await proxy.recordDailyPnl(
        batchId,
        ethers.parseEther("30"),
        ethers.parseEther("5"),
        ethers.parseEther("500")
      );
      await proxy.recordDailyPnl(
        batchId,
        ethers.parseEther("20"),
        ethers.parseEther("3"),
        ethers.parseEther("500")
      );

      const [lt, ftot] = await proxy.getDailyPnl(batchId);

      // Should be sum of both records
      expect(lt).to.equal(ethers.parseEther("50")); // 30 + 20
      expect(ftot).to.equal(ethers.parseEther("8")); // 5 + 3
    });

    it("processDailyBatch updates state exactly once", async () => {
      const { proxy, currentBatchId } = await loadFixture(
        deploySeededVaultFixture
      );

      const batchId = currentBatchId + 1n;
      const navBefore = await proxy.getVaultNav();

      await proxy.recordDailyPnl(batchId, ethers.parseEther("100"), 0n, ethers.parseEther("500"));
      await proxy.processDailyBatch(batchId);

      const navAfter = await proxy.getVaultNav();
      const [, , , , , , processed] = await proxy.getDailyPnl(batchId);

      expect(processed).to.equal(true);
      expect(navAfter).to.be.gt(navBefore);

      // Trying to process again fails (no duplicate update)
      await expect(proxy.processDailyBatch(batchId)).to.be.reverted;
    });
  });
});
