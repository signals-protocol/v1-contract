import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { LPVaultModuleProxy, MockPaymentToken, LPVaultModule } from "../../../typechain-types";
import { WAD, ONE_DAY } from "../../helpers/constants";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * VaultBatchFlow Integration Tests
 *
 * Tests LPVaultModule + VaultAccountingLib integration
 * Reference: docs/vault-invariants.md, whitepaper Section 3
 */

describe("VaultBatchFlow Integration", () => {
  async function deployVaultFixture() {
    const [owner, userA, userB, userC] = await ethers.getSigners();

    // Deploy mock 18-decimal payment token for WAD math testing
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const payment = await MockERC20.deploy("MockVaultToken", "MVT", 18);

    // Deploy LPVaultModule
    const moduleFactory = await ethers.getContractFactory("LPVaultModule");
    const module = await moduleFactory.deploy();

    // Deploy proxy
    const proxyFactory = await ethers.getContractFactory("LPVaultModuleProxy");
    const proxy = await proxyFactory.deploy(module.target) as LPVaultModuleProxy;

    // Configure proxy
    await proxy.setPaymentToken(payment.target);
    await proxy.setMinSeedAmount(ethers.parseEther("100")); // 100 tokens min seed
    await proxy.setWithdrawLag(0); // No lag for testing

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
  // Vault Seeding
  // ============================================================
  describe("Vault seeding", () => {
    it("seeds vault with initial capital", async () => {
      const { proxy, userA, payment } = await loadFixture(deployVaultFixture);

      const seedAmount = ethers.parseEther("1000");
      await proxy.connect(userA).seedVault(seedAmount);

      expect(await proxy.isVaultSeeded()).to.be.true;
      expect(await proxy.getVaultNav()).to.equal(seedAmount);
      expect(await proxy.getVaultShares()).to.equal(seedAmount);
      expect(await proxy.getVaultPrice()).to.equal(WAD); // 1.0
      expect(await proxy.getVaultPricePeak()).to.equal(WAD);
    });

    it("rejects seed below minimum", async () => {
      const { proxy, userA, module } = await loadFixture(deployVaultFixture);

      await expect(proxy.connect(userA).seedVault(ethers.parseEther("50")))
        .to.be.revertedWithCustomError(module, "InsufficientSeedAmount");
    });

    it("rejects double seeding", async () => {
      const { proxy, userA, module } = await loadFixture(deploySeededVaultFixture);

      await expect(proxy.connect(userA).seedVault(ethers.parseEther("1000")))
        .to.be.revertedWithCustomError(module, "VaultAlreadySeeded");
    });
  });

  // ============================================================
  // Daily batch lifecycle
  // ============================================================
  describe("processDailyBatch", () => {
    it("computes preBatchNav from P&L inputs", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      // Initial: N=1000, S=1000
      // P&L: L=-50, F=30, G=10 → Π = -10
      // N_pre = 1000 - 10 = 990
      const pnl = ethers.parseEther("-50"); // Loss
      const fees = ethers.parseEther("30");
      const grant = ethers.parseEther("10");

      await proxy.processBatch(pnl, fees, grant);

      // After batch with no deposits/withdrawals:
      // N_t = N_pre = 990
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("990"));
    });

    it("calculates batch price from preBatchNav and shares", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      // N_pre = 990, S = 1000 → P_e = 0.99
      await proxy.processBatch(ethers.parseEther("-10"), 0n, 0n);

      expect(await proxy.getVaultPrice()).to.equal(ethers.parseEther("0.99"));
    });

    it("updates NAV and shares correctly after batch", async () => {
      const { proxy, userA, userB } = await loadFixture(deploySeededVaultFixture);

      // Add deposit request
      const depositAmount = ethers.parseEther("100");
      await proxy.connect(userB).requestDeposit(depositAmount);

      // Process batch with no P&L
      await proxy.processBatch(0n, 0n, 0n);

      // N = 1000 + 100 = 1100
      // S = 1000 + 100/1.0 = 1100
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1100"));
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("1100"));
    });

    it("updates price and peak after batch", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Positive P&L increases price
      await proxy.processBatch(ethers.parseEther("100"), 0n, 0n);

      // N = 1100, S = 1000 → P = 1.1
      expect(await proxy.getVaultPrice()).to.equal(ethers.parseEther("1.1"));
      expect(await proxy.getVaultPricePeak()).to.equal(ethers.parseEther("1.1"));
    });

    it("emits BatchProcessed event", async () => {
      const { proxy, module } = await loadFixture(deploySeededVaultFixture);

      // Attach module interface to proxy address for events
      const moduleAtProxy = module.attach(proxy.target);

      await expect(proxy.processBatch(0n, 0n, 0n))
        .to.emit(moduleAtProxy, "BatchProcessed");
    });
  });

  // ============================================================
  // P&L flow scenarios
  // ============================================================
  describe("P&L scenarios", () => {
    it("handles positive P&L (L_t > 0)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await proxy.processBatch(ethers.parseEther("100"), 0n, 0n);

      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1100"));
      expect(await proxy.getVaultPrice()).to.equal(ethers.parseEther("1.1"));
    });

    it("handles negative P&L (L_t < 0)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await proxy.processBatch(ethers.parseEther("-200"), 0n, 0n);

      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("800"));
      expect(await proxy.getVaultPrice()).to.equal(ethers.parseEther("0.8"));
    });

    it("handles fee income (F_t > 0)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      await proxy.processBatch(0n, ethers.parseEther("50"), 0n);

      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1050"));
    });

    it("handles backstop grant (G_t > 0)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Loss offset by grant
      await proxy.processBatch(ethers.parseEther("-100"), 0n, ethers.parseEther("100"));

      // N = 1000 - 100 + 100 = 1000
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1000"));
    });

    it("handles combined P&L components", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // L=-50, F=30, G=10 → Π = -10
      await proxy.processBatch(
        ethers.parseEther("-50"),
        ethers.parseEther("30"),
        ethers.parseEther("10")
      );

      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("990"));
    });
  });

  // ============================================================
  // Deposit/Withdraw flow
  // ============================================================
  describe("Deposit flow", () => {
    it("mints shares at batch price", async () => {
      const { proxy, userB } = await loadFixture(deploySeededVaultFixture);

      // Request deposit
      await proxy.connect(userB).requestDeposit(ethers.parseEther("100"));

      // Process batch with P&L that changes price
      await proxy.processBatch(ethers.parseEther("100"), 0n, 0n);

      // N_pre = 1100, S = 1000 → P_e = 1.1
      // Deposit 100 at 1.1 → mint 100/1.1 ≈ 90.909 shares
      // Final S ≈ 1090.909

      const finalShares = await proxy.getVaultShares();
      const expectedShares = ethers.parseEther("1000") + 
        (ethers.parseEther("100") * WAD / ethers.parseEther("1.1"));
      
      const diff = finalShares > expectedShares 
        ? finalShares - expectedShares 
        : expectedShares - finalShares;
      expect(diff).to.be.lte(1n); // Within 1 wei
    });

    it("preserves price within 1 wei", async () => {
      const { proxy, userB } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userB).requestDeposit(ethers.parseEther("500"));
      await proxy.processBatch(0n, 0n, 0n);

      // Price should still be 1.0 (since P&L = 0)
      const price = await proxy.getVaultPrice();
      const diff = price > WAD ? price - WAD : WAD - price;
      expect(diff).to.be.lte(1n);
    });
  });

  describe("Withdraw flow", () => {
    it("burns shares at batch price", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      // Request withdraw (user A has all 1000 shares from seeding)
      await proxy.connect(userA).requestWithdraw(ethers.parseEther("100"));

      await proxy.processBatch(0n, 0n, 0n);

      // S = 1000 - 100 = 900
      expect(await proxy.getVaultShares()).to.equal(ethers.parseEther("900"));
    });

    it("preserves price within 1 wei", async () => {
      const { proxy, userA } = await loadFixture(deploySeededVaultFixture);

      await proxy.connect(userA).requestWithdraw(ethers.parseEther("200"));
      await proxy.processBatch(0n, 0n, 0n);

      const price = await proxy.getVaultPrice();
      const diff = price > WAD ? price - WAD : WAD - price;
      expect(diff).to.be.lte(1n);
    });
  });

  // ============================================================
  // Multi-day sequences
  // ============================================================
  describe("Multi-day sequences", () => {
    it("processes consecutive batches correctly", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Day 1: +10%
      await proxy.processBatch(ethers.parseEther("100"), 0n, 0n);
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1100"));

      // Day 2: -5%
      await proxy.processBatch(ethers.parseEther("-55"), 0n, 0n); // 5% of 1100
      expect(await proxy.getVaultNav()).to.equal(ethers.parseEther("1045"));

      // Day 3: +8%
      await proxy.processBatch(ethers.parseEther("83.6"), 0n, 0n); // ~8% of 1045
      const nav = await proxy.getVaultNav();
      expect(nav).to.be.closeTo(ethers.parseEther("1128.6"), ethers.parseEther("0.1"));
    });

    it("peak tracks highest price across days", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Day 1: +20% → peak = 1.2
      await proxy.processBatch(ethers.parseEther("200"), 0n, 0n);
      expect(await proxy.getVaultPricePeak()).to.equal(ethers.parseEther("1.2"));

      // Day 2: -10% → peak stays at 1.2
      await proxy.processBatch(ethers.parseEther("-120"), 0n, 0n);
      expect(await proxy.getVaultPricePeak()).to.equal(ethers.parseEther("1.2"));

      // Day 3: +30% → peak = 1.2 * 0.9 * 1.3 = 1.404... but check actual
      await proxy.processBatch(ethers.parseEther("324"), 0n, 0n); // 30% of 1080
      const peak = await proxy.getVaultPricePeak();
      expect(peak).to.be.gt(ethers.parseEther("1.2"));
    });
  });

  // ============================================================
  // Edge cases
  // ============================================================
  describe("Edge cases", () => {
    it("handles batch with no P&L and no queue", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      const navBefore = await proxy.getVaultNav();
      await proxy.processBatch(0n, 0n, 0n);
      const navAfter = await proxy.getVaultNav();

      expect(navAfter).to.equal(navBefore);
    });

    it("handles severe loss (clamps NAV at 0)", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Loss > NAV
      await proxy.processBatch(ethers.parseEther("-2000"), 0n, 0n);

      expect(await proxy.getVaultNav()).to.equal(0n);
    });
  });

  // ============================================================
  // Invariant checks
  // ============================================================
  describe("Invariant assertions", () => {
    it("NAV >= 0 after any batch", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Even with huge loss
      await proxy.processBatch(ethers.parseEther("-5000"), 0n, 0n);
      expect(await proxy.getVaultNav()).to.be.gte(0n);
    });

    it("peak >= price always", async () => {
      const { proxy } = await loadFixture(deploySeededVaultFixture);

      // Series of random P&L
      await proxy.processBatch(ethers.parseEther("100"), 0n, 0n);
      await proxy.processBatch(ethers.parseEther("-50"), 0n, 0n);
      await proxy.processBatch(ethers.parseEther("30"), 0n, 0n);
      await proxy.processBatch(ethers.parseEther("-80"), 0n, 0n);

      const price = await proxy.getVaultPrice();
      const peak = await proxy.getVaultPricePeak();
      expect(peak).to.be.gte(price);
    });
  });
});
