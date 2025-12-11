import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockERC20 } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

/**
 * VaultBatchFlow Integration Tests
 *
 * Tests LPVaultModule + VaultAccountingLib integration using Request ID model.
 * Reference: docs/vault-invariants.md, whitepaper Section 3
 */

describe("VaultBatchFlow Integration", () => {
  async function deployVaultFixture() {
    const [owner, userA, userB, userC] = await ethers.getSigners();

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
    await proxy.setWithdrawalLagBatches(0); // Immediate withdrawals for testing

    // Configure FeeWaterfall for batch processing
    await proxy.setFeeWaterfallConfig(
      ethers.parseEther("-0.2"), // pdd = -20%
      0n, // rhoBS
      ethers.parseEther("0.8"), // phiLP = 80%
      ethers.parseEther("0.1"), // phiBS = 10%
      ethers.parseEther("0.1") // phiTR = 10%
    );

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
    await proxy.connect(userA).seedVault(ethers.parseEther("1000"));
    return fixture;
  }

  // Helper to process batch with P&L
  async function processBatchWithPnl(
    proxy: LPVaultModuleProxy,
    batchId: bigint,
    pnl: bigint,
    fees: bigint = 0n
  ) {
    await proxy.recordDailyPnl(batchId, pnl, fees);
    await proxy.processDailyBatch(batchId);
  }

  // ============================================================
  // Vault Seeding
  // ============================================================
  describe("Vault seeding", () => {
    it("seeds vault with initial capital", async () => {
      const { proxy, userA } = await loadFixture(deployVaultFixture);

      const seedAmount = ethers.parseEther("1000");
      await proxy.connect(userA).seedVault(seedAmount);

      expect(await proxy.isVaultSeeded()).to.be.true;
      expect(await proxy.getVaultNav()).to.equal(seedAmount);
      expect(await proxy.getVaultShares()).to.equal(seedAmount);
      expect(await proxy.getVaultPrice()).to.equal(WAD);
      expect(await proxy.getVaultPricePeak()).to.equal(WAD);
    });

    it("rejects seed below minimum", async () => {
      const { proxy, userA, module } = await loadFixture(deployVaultFixture);

      await expect(
        proxy.connect(userA).seedVault(ethers.parseEther("50"))
      ).to.be.revertedWithCustomError(module, "InsufficientSeedAmount");
    });

    it("rejects double seeding", async () => {
      const { proxy, userA, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await expect(
        proxy.connect(userA).seedVault(ethers.parseEther("1000"))
      ).to.be.revertedWithCustomError(module, "VaultAlreadySeeded");
    });
  });

  // ============================================================
  // Daily batch lifecycle
  // ============================================================
  describe("processDailyBatch", () => {
    it("computes preBatchNav from P&L inputs", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Initial: N=1000, S=1000
      // P&L: L=-50, F=30 → Π varies by waterfall
      await processBatchWithPnl(
        proxy,
        1n,
        ethers.parseEther("-50"),
        ethers.parseEther("30")
      );

      // NAV updated according to waterfall
      const nav = await proxy.getVaultNav();
      expect(nav).to.be.lt(ethers.parseEther("1000")); // Loss reduced NAV
    });

    it("calculates batch price from preBatchNav and shares", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // N_pre ≈ 990, S = 1000 → P_e ≈ 0.99
      await processBatchWithPnl(proxy, 1n, ethers.parseEther("-10"), 0n);

      const price = await proxy.getVaultPrice();
      expect(price).to.be.lt(WAD);
    });

    it("updates NAV and shares correctly after deposit", async () => {
      const { proxy, userB } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));
      await processBatchWithPnl(proxy, 1n, 0n, 0n);

      // Claim deposit
      await proxy.connect(userB).claimDeposit(0n);

      // N = 1000 + 100 = 1100
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1100"));
    });

    it("updates price and peak after batch", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Positive P&L increases price
      await processBatchWithPnl(proxy, 1n, ethers.parseEther("100"), 0n);

      const price = await proxy.getVaultPrice();
      const peak = await proxy.getVaultPricePeak();
      expect(price).to.be.gt(WAD);
      expect(peak).to.be.gte(price);
    });

    it("emits DailyBatchProcessed event", async () => {
      const { proxy, module } = await loadFixture(deploySeededVaultFixture);

      const moduleAtProxy = module.attach(proxy.target);

      await proxy.recordDailyPnl(1n, 0n, 0n);
      await expect(proxy.processDailyBatch(1n)).to.emit(
        moduleAtProxy,
        "DailyBatchProcessed"
      );
    });
  });

  // ============================================================
  // P&L flow scenarios
  // ============================================================
  describe("P&L scenarios", () => {
    it("handles positive P&L (L_t > 0, maker profit)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Positive P&L = maker profit (traders lost)
      await processBatchWithPnl(proxy, 1n, ethers.parseEther("100"), 0n);

      expect(await proxy.getVaultNav()).to.be.gt(ethers.parseEther("1000"));
    });

    it("handles negative P&L (L_t < 0, maker loss)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, ethers.parseEther("-200"), 0n);

      expect(await proxy.getVaultNav()).to.be.lt(ethers.parseEther("1000"));
    });

    it("handles fee income (F_t > 0)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Fees get split per waterfall, LP portion increases NAV
      await processBatchWithPnl(proxy, 1n, 0n, ethers.parseEther("50"));

      // LP gets 80% of fees
      expect(await proxy.getVaultNav()).to.be.gte(ethers.parseEther("1000"));
    });

    it("handles combined P&L components", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // L=-50, F=30 → waterfall applies
      await processBatchWithPnl(
        proxy,
        1n,
        ethers.parseEther("-50"),
        ethers.parseEther("30")
      );

      const nav = await proxy.getVaultNav();
      expect(nav).to.be.gt(0n);
    });
  });

  // ============================================================
  // Deposit/Withdraw flow
  // ============================================================
  describe("Deposit flow", () => {
    it("mints shares at batch price", async () => {
      const { proxy, userB } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));

      // Process batch with P&L that changes price
      await processBatchWithPnl(proxy, 1n, ethers.parseEther("100"), 0n);

      // Claim and verify shares
      await proxy.connect(userB).claimDeposit(0n);

      // Price increased, so fewer shares minted
      const shares = await proxy.getVaultShares();
      expect(shares).to.be.lt(ethers.parseEther("1200")); // Less than 1000 + 100 + 100
    });

    it("preserves price within tolerance after deposit", async () => {
      const { proxy, userB } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userB).requestDeposit(ethers.parseEther("500"));
      await processBatchWithPnl(proxy, 1n, 0n, 0n);
      await proxy.connect(userB).claimDeposit(0n);

      const price = await proxy.getVaultPrice();
      const diff = price > WAD ? price - WAD : WAD - price;
      expect(diff).to.be.lte(10n); // Within small tolerance
    });
  });

  describe("Withdraw flow", () => {
    it("burns shares at batch price", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));
      await processBatchWithPnl(proxy, 1n, 0n, 0n);
      await proxy.connect(userA).claimWithdraw(0n);

      // S = 1000 - 100 = 900
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("900"));
    });

    it("preserves price within tolerance after withdraw", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("200"));
      await processBatchWithPnl(proxy, 1n, 0n, 0n);
      await proxy.connect(userA).claimWithdraw(0n);

      const price = await proxy.getVaultPrice();
      const diff = price > WAD ? price - WAD : WAD - price;
      expect(diff).to.be.lte(10n);
    });
  });

  // ============================================================
  // Multi-day sequences
  // ============================================================
  describe("Multi-day sequences", () => {
    it("processes consecutive batches correctly", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Day 1: +10%
      await processBatchWithPnl(proxy, 1n, ethers.parseEther("100"), 0n);
      expect(await proxy.getVaultNav()).to.be.gte(ethers.parseEther("1090"));

      // Day 2: -5%
      await processBatchWithPnl(proxy, 2n, ethers.parseEther("-55"), 0n);

      // Day 3: +8%
      await processBatchWithPnl(proxy, 3n, ethers.parseEther("80"), 0n);

      const nav = await proxy.getVaultNav();
      expect(nav).to.be.gt(ethers.parseEther("1000"));
    });

    it("peak tracks highest price across days", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Day 1: +20% → peak = 1.2
      await processBatchWithPnl(proxy, 1n, ethers.parseEther("200"), 0n);
      const peak1 = await proxy.getVaultPricePeak();

      // Day 2: -10% → peak stays
      await processBatchWithPnl(proxy, 2n, ethers.parseEther("-120"), 0n);
      const peak2 = await proxy.getVaultPricePeak();
      expect(peak2).to.equal(peak1);

      // Day 3: +30% → peak increases
      await processBatchWithPnl(proxy, 3n, ethers.parseEther("300"), 0n);
      const peak3 = await proxy.getVaultPricePeak();
      expect(peak3).to.be.gt(peak1);
    });
  });

  // ============================================================
  // Edge cases
  // ============================================================
  describe("Edge cases", () => {
    it("handles batch with no P&L and no queue", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      const navBefore = await proxy.getVaultNav();
      await processBatchWithPnl(proxy, 1n, 0n, 0n);
      const navAfter = await proxy.getVaultNav();

      expect(navAfter).to.equal(navBefore);
    });

    it("handles empty batch (no deposits, no withdrawals)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, ethers.parseEther("50"), 0n);

      // Should process without error
      expect(await proxy.getVaultNav()).to.be.gt(ethers.parseEther("1000"));
    });
  });

  // ============================================================
  // Multi-user concurrent operations
  // ============================================================
  describe("Multi-user concurrent operations", () => {
    it("handles multiple users depositing in same batch", async () => {
      const { proxy, userA, userB, userC } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(ethers.parseEther("100"));
      await proxy.connect(userB).requestDeposit(ethers.parseEther("200"));
      await proxy.connect(userC).requestDeposit(ethers.parseEther("300"));

      await processBatchWithPnl(proxy, 1n, 0n, 0n);

      // All users claim
      await proxy.connect(userA).claimDeposit(0n);
      await proxy.connect(userB).claimDeposit(1n);
      await proxy.connect(userC).claimDeposit(2n);

      // Total deposits: 600
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1600"));
    });

    it("handles mixed deposit/withdraw from multiple users", async () => {
      const { proxy, userA, userB, userC } = await loadFixture(
        deploySeededVaultFixture
      );

      // userA withdraws (has shares from seed)
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("200"));
      // userB and userC deposit
      await proxy.connect(userB).requestDeposit(ethers.parseEther("150"));
      await proxy.connect(userC).requestDeposit(ethers.parseEther("100"));

      await processBatchWithPnl(proxy, 1n, 0n, 0n);

      // Claims
      await proxy.connect(userA).claimWithdraw(0n);
      await proxy.connect(userB).claimDeposit(0n);
      await proxy.connect(userC).claimDeposit(1n);

      // Net: -200 + 150 + 100 = +50
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1050"));
    });
  });

  // ============================================================
  // Request cancellation
  // ============================================================
  describe("Request cancellation", () => {
    it("allows cancel before batch processed", async () => {
      const { proxy, userB, payment } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));

      const balanceBefore = await payment.balanceOf(userB.address);
      await proxy.connect(userB).cancelDeposit(0n);
      const balanceAfter = await payment.balanceOf(userB.address);

      expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("100"));
    });

    it("prevents cancel after claim", async () => {
      const { proxy, userB, module } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));
      await processBatchWithPnl(proxy, 1n, 0n, 0n);
      await proxy.connect(userB).claimDeposit(0n);

      // Cancel should fail
      await expect(
        proxy.connect(userB).cancelDeposit(0n)
      ).to.be.revertedWithCustomError(module, "RequestNotPending");
    });
  });

  // ============================================================
  // Batch sequence enforcement
  // ============================================================
  describe("Batch sequence enforcement", () => {
    it("rejects out-of-sequence batch", async () => {
      const { proxy, module } = await loadFixture(deploySeededVaultFixture);

      // Try to process batch 5 when expecting batch 1
      await proxy.recordDailyPnl(5n, 0n, 0n);
      await expect(proxy.processDailyBatch(5n)).to.be.revertedWithCustomError(
        module,
        "BatchNotReady"
      );
    });

    it("prevents duplicate batch processing", async () => {
      const { proxy, module } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, 0n, 0n);

      // Try to process same batch again
      // This fails with BatchNotReady because currentBatchId is now 1,
      // and we're trying to process 1 again (expects 2)
      await expect(proxy.processDailyBatch(1n)).to.be.revertedWithCustomError(
        module,
        "BatchNotReady"
      );
    });

    it("allows sequential batches", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, 0n, 0n);
      await processBatchWithPnl(proxy, 2n, 0n, 0n);
      await processBatchWithPnl(proxy, 3n, 0n, 0n);

      expect(await proxy.getCurrentBatchId()).to.equal(3n);
    });
  });

  // ============================================================
  // Invariant assertions
  // ============================================================
  describe("Invariant assertions", () => {
    it("NAV >= 0 after any batch", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, ethers.parseEther("-500"), 0n);

      expect(await proxy.getVaultNav()).to.be.gte(0n);
    });

    it("shares >= 0 after any batch", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, ethers.parseEther("100"), 0n);

      expect(await proxy.getVaultShares()).to.be.gte(0n);
    });

    it("price > 0 when shares > 0", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      const shares = await proxy.getVaultShares();
      if (shares > 0n) {
        expect(await proxy.getVaultPrice()).to.be.gt(0n);
      }
    });

    it("peak >= price always", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, ethers.parseEther("100"), 0n);
      await processBatchWithPnl(proxy, 2n, ethers.parseEther("-50"), 0n);

      const price = await proxy.getVaultPrice();
      const peak = await proxy.getVaultPricePeak();
      expect(peak).to.be.gte(price);
    });

    it("0 <= drawdown <= 100%", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await processBatchWithPnl(proxy, 1n, ethers.parseEther("200"), 0n);
      await processBatchWithPnl(proxy, 2n, ethers.parseEther("-300"), 0n);

      const price = await proxy.getVaultPrice();
      const peak = await proxy.getVaultPricePeak();
      const drawdown = WAD - (price * WAD) / peak;

      expect(drawdown).to.be.gte(0n);
      expect(drawdown).to.be.lte(WAD);
    });
  });

  // ============================================================
  // Pre-aggregation invariant
  // ============================================================
  describe("Pre-aggregation invariant", () => {
    it("pending totals reflect sum of requests", async () => {
      const { proxy, userA, userB, userC } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(ethers.parseEther("100"));
      await proxy.connect(userB).requestDeposit(ethers.parseEther("200"));
      await proxy.connect(userC).requestDeposit(ethers.parseEther("300"));

      const [deposits, withdraws] = await proxy.getPendingBatchTotals(1n);
      expect(deposits).to.equal(ethers.parseEther("600"));
      expect(withdraws).to.equal(0n);
    });

    it("cancel updates pending totals correctly", async () => {
      const { proxy, userA, userB } = await loadFixture(
        deploySeededVaultFixture
      );

      await proxy.connect(userA).requestDeposit(ethers.parseEther("100"));
      await proxy.connect(userB).requestDeposit(ethers.parseEther("200"));

      // Cancel userA
      await proxy.connect(userA).cancelDeposit(0n);

      const [deposits] = await proxy.getPendingBatchTotals(1n);
      expect(deposits).to.equal(ethers.parseEther("200"));
    });
  });
});
