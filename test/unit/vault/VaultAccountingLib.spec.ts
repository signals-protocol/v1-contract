import { expect } from "chai";
import { ethers } from "hardhat";
import { VaultAccountingLibTest } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

/**
 * VaultAccountingLib Unit Tests
 *
 * Reference: docs/vault-invariants.md, whitepaper Section 3
 *
 * Invariants:
 * - INV-V1: N^pre_t = N_{t-1} + L_t + F_t + G_t
 * - INV-V2: P^e_t = N^pre_t / S_{t-1}
 * - INV-V3: Seeding sets price to 1e18
 * - INV-V4: Deposit preserves price |N'/S' - P| <= 1 wei
 * - INV-V5: Withdraw preserves price |N''/S'' - P| <= 1 wei
 * - INV-V6: Withdraw bounds check
 * - INV-V7: Peak monotonicity
 * - INV-V8: Drawdown range [0, 1e18]
 */

describe("VaultAccountingLib", () => {
  let lib: VaultAccountingLibTest;

  before(async () => {
    const factory = await ethers.getContractFactory("VaultAccountingLibTest");
    lib = await factory.deploy();
    await lib.waitForDeployment();
  });

  // ============================================================
  // INV-V1: Pre-batch NAV calculation
  // N_pre,t = N_{t-1} + L_t + F_t + G_t
  // ============================================================
  describe("INV-V1: computePreBatch NAV", () => {
    it("calculates preBatchNav = navPrev + L + F + G", async () => {
      const navPrev = ethers.parseEther("1000");
      const sharesPrev = ethers.parseEther("900");
      const pnl = ethers.parseEther("-50"); // signed
      const fees = ethers.parseEther("30");
      const grant = ethers.parseEther("10");

      const [navPre] = await lib.computePreBatch(navPrev, sharesPrev, pnl, fees, grant);

      // N_pre = 1000 - 50 + 30 + 10 = 990
      expect(navPre).to.equal(ethers.parseEther("990"));
    });

    it("handles positive P&L", async () => {
      const navPrev = ethers.parseEther("1000");
      const sharesPrev = ethers.parseEther("1000");
      const pnl = ethers.parseEther("100"); // positive P&L
      const fees = ethers.parseEther("20");
      const grant = 0n;

      const [navPre] = await lib.computePreBatch(navPrev, sharesPrev, pnl, fees, grant);

      // N_pre = 1000 + 100 + 20 + 0 = 1120
      expect(navPre).to.equal(ethers.parseEther("1120"));
    });

    it("handles zero inputs (no change)", async () => {
      const navPrev = ethers.parseEther("1000");
      const sharesPrev = ethers.parseEther("1000");

      const [navPre] = await lib.computePreBatch(navPrev, sharesPrev, 0n, 0n, 0n);

      expect(navPre).to.equal(navPrev);
    });

    it("clamps NAV at 0 when loss exceeds nav", async () => {
      const navPrev = ethers.parseEther("100");
      const sharesPrev = ethers.parseEther("100");
      const pnl = ethers.parseEther("-200"); // loss > nav

      const [navPre] = await lib.computePreBatch(navPrev, sharesPrev, pnl, 0n, 0n);

      expect(navPre).to.equal(0n);
    });
  });

  // ============================================================
  // INV-V2: Batch price calculation
  // P_e,t = N_pre,t / S_{t-1}
  // ============================================================
  describe("INV-V2: computePreBatch price", () => {
    it("calculates batchPrice = preBatchNav / sharesPrev", async () => {
      const navPrev = ethers.parseEther("1000");
      const sharesPrev = ethers.parseEther("900");
      // Π = 0, so navPre = 1000

      const [navPre, batchPrice] = await lib.computePreBatch(navPrev, sharesPrev, 0n, 0n, 0n);

      // P_e = 1000 / 900 ≈ 1.111...e18
      const expectedPrice = navPre * WAD / sharesPrev;
      expect(batchPrice).to.equal(expectedPrice);
    });

    it("handles high precision division", async () => {
      const navPrev = ethers.parseEther("990");
      const sharesPrev = ethers.parseEther("900");

      const [navPre, batchPrice] = await lib.computePreBatch(navPrev, sharesPrev, 0n, 0n, 0n);

      // P_e = 990 / 900 = 1.1e18
      expect(batchPrice).to.equal(ethers.parseEther("1.1"));
    });

    it("reverts when sharesPrev = 0", async () => {
      const navPrev = ethers.parseEther("1000");

      await expect(lib.computePreBatch(navPrev, 0n, 0n, 0n, 0n))
        .to.be.revertedWithCustomError(lib, "ZeroSharesNotAllowed");
    });
  });

  // ============================================================
  // INV-V3: Seeding (shares=0 initialization)
  // ============================================================
  describe("INV-V3: Vault seeding", () => {
    it("sets initial price to 1e18 on seed", async () => {
      const [navPre, batchPrice] = await lib.computePreBatchForSeed(0n, 0n, 0n, 0n);

      expect(batchPrice).to.equal(WAD);
    });

    it("handles non-zero initial nav on seed", async () => {
      const [navPre, batchPrice] = await lib.computePreBatchForSeed(
        ethers.parseEther("100"), 0n, 0n, 0n
      );

      expect(navPre).to.equal(ethers.parseEther("100"));
      expect(batchPrice).to.equal(WAD); // Still 1e18 for seeding
    });
  });

  // ============================================================
  // INV-V4: Deposit price preservation
  // After deposit D: N' = N + D, S' = S + D/P, |N'/S' - P| <= 1 wei
  // ============================================================
  describe("INV-V4: applyDeposit", () => {
    it("increases NAV and shares proportionally", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1"); // P = 1.0
      const deposit = ethers.parseEther("100");

      const [newNav, newShares, minted] = await lib.applyDeposit(nav, shares, price, deposit);

      expect(newNav).to.equal(ethers.parseEther("1100"));
      expect(minted).to.equal(ethers.parseEther("100"));
      expect(newShares).to.equal(ethers.parseEther("1100"));
    });

    it("preserves price within 1 wei after deposit", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("900");
      const price = (nav * WAD) / shares; // ~1.111e18
      const deposit = ethers.parseEther("100");

      const [newNav, newShares] = await lib.applyDeposit(nav, shares, price, deposit);
      const newPrice = (newNav * WAD) / newShares;

      // Price preservation: |newPrice - price| <= 1 wei
      const diff = newPrice > price ? newPrice - price : price - newPrice;
      expect(diff).to.be.lte(1n);
    });

    it("handles large deposit", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");
      const deposit = ethers.parseEther("1000000"); // 1M deposit

      const [newNav, newShares] = await lib.applyDeposit(nav, shares, price, deposit);

      expect(newNav).to.equal(ethers.parseEther("1001000"));
      expect(newShares).to.equal(ethers.parseEther("1001000"));
    });

    it("reverts with zero price", async () => {
      await expect(lib.applyDeposit(WAD, WAD, 0n, WAD))
        .to.be.revertedWithCustomError(lib, "ZeroPriceNotAllowed");
    });
  });

  // ============================================================
  // INV-V5: Withdraw price preservation
  // After withdraw x: N'' = N - x·P, S'' = S - x, |N''/S'' - P| <= 1 wei
  // ============================================================
  describe("INV-V5: applyWithdraw", () => {
    it("decreases NAV and shares proportionally", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");
      const withdrawShares = ethers.parseEther("50");

      const [newNav, newShares, withdrawAmount] = await lib.applyWithdraw(
        nav, shares, price, withdrawShares
      );

      expect(newNav).to.equal(ethers.parseEther("950"));
      expect(newShares).to.equal(ethers.parseEther("950"));
      expect(withdrawAmount).to.equal(ethers.parseEther("50"));
    });

    it("preserves price within 1 wei after withdraw", async () => {
      const nav = ethers.parseEther("1100");
      const shares = ethers.parseEther("1000");
      const price = (nav * WAD) / shares; // 1.1e18
      const withdrawShares = ethers.parseEther("100");

      const [newNav, newShares] = await lib.applyWithdraw(nav, shares, price, withdrawShares);
      
      // New price calculation
      const newPrice = newShares > 0n ? (newNav * WAD) / newShares : WAD;

      // Price preservation
      const diff = newPrice > price ? newPrice - price : price - newPrice;
      expect(diff).to.be.lte(1n);
    });

    it("handles full withdrawal", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");

      const [newNav, newShares, withdrawAmount] = await lib.applyWithdraw(
        nav, shares, price, shares
      );

      expect(newNav).to.equal(0n);
      expect(newShares).to.equal(0n);
      expect(withdrawAmount).to.equal(nav);
    });
  });

  // ============================================================
  // INV-V6: Withdraw bounds
  // ============================================================
  describe("INV-V6: Withdraw bounds", () => {
    it("reverts when withdrawShares > totalShares", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");
      const tooMany = ethers.parseEther("1001");

      await expect(lib.applyWithdraw(nav, shares, price, tooMany))
        .to.be.revertedWithCustomError(lib, "InsufficientShares")
        .withArgs(tooMany, shares);
    });

    it("reverts when withdrawAmount > NAV (edge case)", async () => {
      // This can happen if price * shares > nav due to rounding
      const nav = ethers.parseEther("99"); // Slightly less than shares * price
      const shares = ethers.parseEther("100");
      const price = ethers.parseEther("1");
      const withdrawShares = ethers.parseEther("100");

      await expect(lib.applyWithdraw(nav, shares, price, withdrawShares))
        .to.be.revertedWithCustomError(lib, "InsufficientNAV");
    });
  });

  // ============================================================
  // INV-V7: Peak monotonicity
  // P_peak,t >= P_peak,{t-1}
  // ============================================================
  describe("INV-V7: Peak monotonicity", () => {
    it("updates peak when price exceeds current peak", async () => {
      const currentPeak = ethers.parseEther("1");
      const newPrice = ethers.parseEther("1.2");

      const updatedPeak = await lib.updatePeak(currentPeak, newPrice);

      expect(updatedPeak).to.equal(newPrice);
    });

    it("keeps peak when price is lower", async () => {
      const currentPeak = ethers.parseEther("1.2");
      const newPrice = ethers.parseEther("1");

      const updatedPeak = await lib.updatePeak(currentPeak, newPrice);

      expect(updatedPeak).to.equal(currentPeak);
    });

    it("handles equal price and peak", async () => {
      const currentPeak = ethers.parseEther("1");
      const newPrice = ethers.parseEther("1");

      const updatedPeak = await lib.updatePeak(currentPeak, newPrice);

      expect(updatedPeak).to.equal(currentPeak);
    });

    it("sequence of prices maintains monotonic peak", async () => {
      const prices = [1.0, 1.2, 1.1, 1.3, 0.9, 1.5];
      let peak = 0n;

      for (const p of prices) {
        const price = ethers.parseEther(p.toString());
        const newPeak = await lib.updatePeak(peak, price);
        expect(newPeak).to.be.gte(peak);
        peak = newPeak;
      }

      expect(peak).to.equal(ethers.parseEther("1.5"));
    });
  });

  // ============================================================
  // INV-V8: Drawdown range [0, 1e18]
  // DD_t = 1 - P_t / P_peak,t
  // ============================================================
  describe("INV-V8: Drawdown calculation", () => {
    it("returns 0 when price equals peak", async () => {
      const price = ethers.parseEther("1");
      const peak = ethers.parseEther("1");

      const dd = await lib.computeDrawdown(price, peak);

      expect(dd).to.equal(0n);
    });

    it("calculates 20% drawdown correctly", async () => {
      const price = ethers.parseEther("0.8");
      const peak = ethers.parseEther("1");

      const dd = await lib.computeDrawdown(price, peak);

      // DD = 1 - 0.8/1.0 = 0.2
      expect(dd).to.equal(ethers.parseEther("0.2"));
    });

    it("returns 100% drawdown when price is 0", async () => {
      const price = 0n;
      const peak = ethers.parseEther("1");

      const dd = await lib.computeDrawdown(price, peak);

      expect(dd).to.equal(ethers.parseEther("1"));
    });

    it("returns 0 when peak is 0", async () => {
      const dd = await lib.computeDrawdown(0n, 0n);
      expect(dd).to.equal(0n);
    });

    it("returns 0 when price exceeds peak", async () => {
      const price = ethers.parseEther("1.2");
      const peak = ethers.parseEther("1");

      const dd = await lib.computeDrawdown(price, peak);

      expect(dd).to.equal(0n);
    });

    it("handles small drawdown precision", async () => {
      const peak = ethers.parseEther("1");
      const price = ethers.parseEther("0.999"); // 0.1% drawdown

      const dd = await lib.computeDrawdown(price, peak);

      // DD = 0.001 = 1e15 wei
      expect(dd).to.equal(ethers.parseEther("0.001"));
    });
  });

  // ============================================================
  // Full batch processing
  // ============================================================
  describe("computePostBatchState", () => {
    it("computes complete post-batch state", async () => {
      const nav = ethers.parseEther("1100");
      const shares = ethers.parseEther("1000");
      const previousPeak = ethers.parseEther("1");

      const [navOut, sharesOut, price, pricePeak, drawdown] = await lib.computePostBatchState(
        nav, shares, previousPeak
      );

      expect(navOut).to.equal(nav);
      expect(sharesOut).to.equal(shares);
      expect(price).to.equal(ethers.parseEther("1.1"));
      expect(pricePeak).to.equal(ethers.parseEther("1.1")); // New peak
      expect(drawdown).to.equal(0n); // At peak, no drawdown
    });

    it("tracks drawdown from previous peak", async () => {
      const nav = ethers.parseEther("900");
      const shares = ethers.parseEther("1000");
      const previousPeak = ethers.parseEther("1.2");

      const [, , price, pricePeak, drawdown] = await lib.computePostBatchState(
        nav, shares, previousPeak
      );

      expect(price).to.equal(ethers.parseEther("0.9"));
      expect(pricePeak).to.equal(previousPeak); // Peak unchanged
      // DD = 1 - 0.9/1.2 = 0.25
      expect(drawdown).to.equal(ethers.parseEther("0.25"));
    });
  });

  // ============================================================
  // Property tests
  // ============================================================
  describe("Property: price preservation round-trip", () => {
    it("deposit then withdraw same amount preserves state", async () => {
      const initialNav = ethers.parseEther("1000");
      const initialShares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");
      const amount = ethers.parseEther("100");

      // Deposit
      const [navAfterDeposit, sharesAfterDeposit, minted] = await lib.applyDeposit(
        initialNav, initialShares, price, amount
      );

      // Withdraw same shares
      const [finalNav, finalShares] = await lib.applyWithdraw(
        navAfterDeposit, sharesAfterDeposit, price, minted
      );

      // Should return to initial state (within rounding)
      const navDiff = finalNav > initialNav ? finalNav - initialNav : initialNav - finalNav;
      const sharesDiff = finalShares > initialShares 
        ? finalShares - initialShares 
        : initialShares - finalShares;

      expect(navDiff).to.be.lte(1n);
      expect(sharesDiff).to.equal(0n);
    });

    it("multiple deposits/withdraws preserve price invariant", async () => {
      let nav = ethers.parseEther("1000");
      let shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");

      // Multiple operations
      [nav, shares] = (await lib.applyDeposit(nav, shares, price, ethers.parseEther("50"))).slice(0, 2) as [bigint, bigint];
      [nav, shares] = (await lib.applyDeposit(nav, shares, price, ethers.parseEther("30"))).slice(0, 2) as [bigint, bigint];
      [nav, shares] = (await lib.applyWithdraw(nav, shares, price, ethers.parseEther("20"))).slice(0, 2) as [bigint, bigint];
      [nav, shares] = (await lib.applyDeposit(nav, shares, price, ethers.parseEther("100"))).slice(0, 2) as [bigint, bigint];

      // Final price should still be ~1.0
      const finalPrice = shares > 0n ? (nav * WAD) / shares : WAD;
      const diff = finalPrice > price ? finalPrice - price : price - finalPrice;

      // Allow slightly more tolerance due to multiple operations
      expect(diff).to.be.lte(5n);
    });
  });

  describe("Property: arithmetic bounds", () => {
    it("handles maximum WAD values without overflow", async () => {
      const maxNav = ethers.parseEther("1000000000"); // 1B tokens
      const maxShares = ethers.parseEther("1000000000");

      // Should not overflow
      const [navPre, batchPrice] = await lib.computePreBatch(
        maxNav, maxShares, 0n, 0n, 0n
      );

      expect(navPre).to.equal(maxNav);
      expect(batchPrice).to.equal(WAD); // 1.0 since nav == shares
    });

    it("handles minimum non-zero values without underflow", async () => {
      const minNav = 1n;
      const minShares = 1n;

      const [navPre, batchPrice] = await lib.computePreBatch(
        minNav, minShares, 0n, 0n, 0n
      );

      expect(navPre).to.equal(minNav);
      expect(batchPrice).to.equal(WAD); // 1/1 * WAD = WAD
    });
  });
});
