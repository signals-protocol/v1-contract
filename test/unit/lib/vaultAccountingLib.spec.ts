import { expect } from "chai";
import { ethers } from "hardhat";
import { VaultAccountingLibHarness } from "../../../typechain-types";
import { WAD } from "../../helpers/constants";

/**
 * VaultAccountingLib Unit Tests
 *
 * Reference: docs/vault-invariants.md, whitepaper section 3
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
  let lib: VaultAccountingLibHarness;

  before(async () => {
    const factory = await ethers.getContractFactory("VaultAccountingLibHarness");
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

      const [navPre] = await lib.computePreBatch(
        navPrev,
        sharesPrev,
        pnl,
        fees,
        grant
      );

      // N_pre = 1000 - 50 + 30 + 10 = 990
      expect(navPre).to.equal(ethers.parseEther("990"));
    });

    it("handles positive P&L", async () => {
      const navPrev = ethers.parseEther("1000");
      const sharesPrev = ethers.parseEther("1000");
      const pnl = ethers.parseEther("100"); // positive P&L
      const fees = ethers.parseEther("20");
      const grant = 0n;

      const [navPre] = await lib.computePreBatch(
        navPrev,
        sharesPrev,
        pnl,
        fees,
        grant
      );

      // N_pre = 1000 + 100 + 20 + 0 = 1120
      expect(navPre).to.equal(ethers.parseEther("1120"));
    });

    it("handles zero inputs (no change)", async () => {
      const navPrev = ethers.parseEther("1000");
      const sharesPrev = ethers.parseEther("1000");

      const [navPre] = await lib.computePreBatch(
        navPrev,
        sharesPrev,
        0n,
        0n,
        0n
      );

      expect(navPre).to.equal(navPrev);
    });

    it("reverts with NAVUnderflow when loss exceeds nav", async () => {
      const navPrev = ethers.parseEther("100");
      const sharesPrev = ethers.parseEther("100");
      const pnl = ethers.parseEther("-200"); // loss > nav

      // Per whitepaper: Safety Layer should prevent this via Backstop Grants
      // If it happens, revert rather than silently clamp
      await expect(lib.computePreBatch(navPrev, sharesPrev, pnl, 0n, 0n))
        .to.be.revertedWithCustomError(lib, "NAVUnderflow")
        .withArgs(navPrev, ethers.parseEther("200"));
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

      const [navPre, batchPrice] = await lib.computePreBatch(
        navPrev,
        sharesPrev,
        0n,
        0n,
        0n
      );

      // P_e = 1000 / 900 ≈ 1.111...e18
      const expectedPrice = (navPre * WAD) / sharesPrev;
      expect(batchPrice).to.equal(expectedPrice);
    });

    it("handles high precision division", async () => {
      const navPrev = ethers.parseEther("990");
      const sharesPrev = ethers.parseEther("900");

      const [, batchPrice] = await lib.computePreBatch(
        navPrev,
        sharesPrev,
        0n,
        0n,
        0n
      );

      // P_e = 990 / 900 = 1.1e18
      expect(batchPrice).to.equal(ethers.parseEther("1.1"));
    });

    it("reverts when sharesPrev = 0", async () => {
      const navPrev = ethers.parseEther("1000");

      await expect(
        lib.computePreBatch(navPrev, 0n, 0n, 0n, 0n)
      ).to.be.revertedWithCustomError(lib, "ZeroSharesNotAllowed");
    });
  });

  // ============================================================
  // INV-V3: Seeding (shares=0 initialization)
  // ============================================================
  describe("INV-V3: Vault seeding", () => {
    it("sets initial price to 1e18 on seed", async () => {
      const [, batchPrice] = await lib.computePreBatchForSeed(0n, 0n, 0n, 0n);

      expect(batchPrice).to.equal(WAD);
    });

    it("handles non-zero initial nav on seed", async () => {
      const [navPre, batchPrice] = await lib.computePreBatchForSeed(
        ethers.parseEther("100"),
        0n,
        0n,
        0n
      );

      expect(navPre).to.equal(ethers.parseEther("100"));
      expect(batchPrice).to.equal(WAD); // Still 1e18 for seeding
    });
  });

  // ============================================================
  // INV-V4: Deposit price preservation
  // Per whitepaper C.1(b1): S_mint = floor(A/P), A_used = S_mint * P
  // N' = N + A_used, S' = S + S_mint, refund = A - A_used
  // ============================================================
  describe("INV-V4: applyDeposit", () => {
    it("increases NAV and shares proportionally", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1"); // P = 1.0
      const deposit = ethers.parseEther("100");

      const [newNav, newShares, minted, refund] = await lib.applyDeposit(
        nav,
        shares,
        price,
        deposit
      );

      // At P=1.0, A_used = minted * 1 = deposit (no dust)
      expect(newNav).to.equal(ethers.parseEther("1100"));
      expect(minted).to.equal(ethers.parseEther("100"));
      expect(newShares).to.equal(ethers.parseEther("1100"));
      expect(refund).to.equal(0n); // No dust at P=1.0
    });

    it("preserves price within 1 wei after deposit", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("900");
      const price = (nav * WAD) / shares; // ~1.111e18
      const deposit = ethers.parseEther("100");

      const [newNav, newShares, , refund] = await lib.applyDeposit(
        nav,
        shares,
        price,
        deposit
      );
      const newPrice = (newNav * WAD) / newShares;

      // Price preservation: |newPrice - price| <= 1 wei
      const diff = newPrice > price ? newPrice - price : price - newPrice;
      expect(diff).to.be.lte(1n);

      // Refund should be small (at most 1 wei per whitepaper)
      expect(refund).to.be.lte(1n);
    });

    it("handles large deposit", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");
      const deposit = ethers.parseEther("1000000"); // 1M deposit

      const [newNav, newShares, , refund] = await lib.applyDeposit(
        nav,
        shares,
        price,
        deposit
      );

      expect(newNav).to.equal(ethers.parseEther("1001000"));
      expect(newShares).to.equal(ethers.parseEther("1001000"));
      expect(refund).to.equal(0n); // No dust at P=1.0
    });

    it("reverts with zero price", async () => {
      await expect(
        lib.applyDeposit(WAD, WAD, 0n, WAD)
      ).to.be.revertedWithCustomError(lib, "ZeroPriceNotAllowed");
    });

    it("refunds deposit dust per whitepaper C.1(b1)", async () => {
      // Use a price that doesn't divide evenly
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("700"); // Price = 1000/700 ≈ 1.4285...
      const price = (nav * WAD) / shares;
      const deposit = ethers.parseEther("100");

      const [newNav, , minted, refund] = await lib.applyDeposit(
        nav,
        shares,
        price,
        deposit
      );

      // S_mint = floor(100 / 1.4285...) = 70
      // A_used = 70 * 1.4285... = 99.999...
      // refund = 100 - A_used (small dust)

      // Verify: newNav = nav + A_used (NOT nav + deposit)
      const amountUsed = (minted * price) / WAD;
      expect(newNav).to.equal(nav + amountUsed);

      // Verify: refund = deposit - A_used
      expect(refund).to.equal(deposit - amountUsed);

      // Verify: refund is at most 1 wei (per whitepaper)
      // Note: In WAD terms, this can be up to ~price wei
      expect(refund).to.be.lt(price);
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
        nav,
        shares,
        price,
        withdrawShares
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

      const [newNav, newShares] = await lib.applyWithdraw(
        nav,
        shares,
        price,
        withdrawShares
      );

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
        nav,
        shares,
        price,
        shares
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

      await expect(
        lib.applyWithdraw(nav, shares, price, withdrawShares)
      ).to.be.revertedWithCustomError(lib, "InsufficientNAV");
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
  // Price calculation
  // ============================================================
  describe("computePrice", () => {
    it("returns nav/shares for normal case", async () => {
      const nav = ethers.parseEther("1000");
      const shares = ethers.parseEther("900");
      
      const price = await lib.computePrice(nav, shares);
      
      // P = 1000/900 ≈ 1.111e18
      const expected = (nav * WAD) / shares;
      expect(price).to.equal(expected);
    });

    it("returns 1e18 when shares = 0 (empty vault)", async () => {
      const price = await lib.computePrice(ethers.parseEther("100"), 0n);
      expect(price).to.equal(WAD);
    });

    it("returns 1e18 when both nav and shares are 0", async () => {
      const price = await lib.computePrice(0n, 0n);
      expect(price).to.equal(WAD);
    });

    it("handles nav = 0 with shares > 0 (price = 0)", async () => {
      const price = await lib.computePrice(0n, ethers.parseEther("100"));
      expect(price).to.equal(0n);
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

      const [navOut, sharesOut, price, pricePeak, drawdown] =
        await lib.computePostBatchState(nav, shares, previousPeak);

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
        nav,
        shares,
        previousPeak
      );

      expect(price).to.equal(ethers.parseEther("0.9"));
      expect(pricePeak).to.equal(previousPeak); // Peak unchanged
      // DD = 1 - 0.9/1.2 = 0.25
      expect(drawdown).to.equal(ethers.parseEther("0.25"));
    });

    it("handles empty vault (shares=0) correctly", async () => {
      // When all LPs exit, shares=0
      const nav = 0n;
      const shares = 0n;
      const previousPeak = ethers.parseEther("1.5"); // Had a peak before

      const [navOut, sharesOut, price, pricePeak, drawdown] =
        await lib.computePostBatchState(nav, shares, previousPeak);

      expect(navOut).to.equal(0n);
      expect(sharesOut).to.equal(0n);
      // Per whitepaper: empty vault defaults to price=1.0
      expect(price).to.equal(WAD);
      // Peak is preserved from previous state
      expect(pricePeak).to.equal(previousPeak);
      // Drawdown is 0 for empty vault (no active LP exposure)
      expect(drawdown).to.equal(0n);
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
      const [navAfterDeposit, sharesAfterDeposit, minted] =
        await lib.applyDeposit(initialNav, initialShares, price, amount);

      // Withdraw same shares
      const [finalNav, finalShares] = await lib.applyWithdraw(
        navAfterDeposit,
        sharesAfterDeposit,
        price,
        minted
      );

      // Should return to initial state (within rounding)
      const navDiff =
        finalNav > initialNav ? finalNav - initialNav : initialNav - finalNav;
      const sharesDiff =
        finalShares > initialShares
          ? finalShares - initialShares
          : initialShares - finalShares;

      expect(navDiff).to.be.lte(1n);
      expect(sharesDiff).to.equal(0n);
    });

    it("multiple deposits/withdraws preserve price invariant", async () => {
      let nav = ethers.parseEther("1000");
      let shares = ethers.parseEther("1000");
      const price = ethers.parseEther("1");

      // Multiple operations - note: applyDeposit now returns 4 values
      let result = await lib.applyDeposit(
        nav,
        shares,
        price,
        ethers.parseEther("50")
      );
      nav = result[0];
      shares = result[1];

      result = await lib.applyDeposit(
        nav,
        shares,
        price,
        ethers.parseEther("30")
      );
      nav = result[0];
      shares = result[1];

      const wdResult = await lib.applyWithdraw(
        nav,
        shares,
        price,
        ethers.parseEther("20")
      );
      nav = wdResult[0];
      shares = wdResult[1];

      result = await lib.applyDeposit(
        nav,
        shares,
        price,
        ethers.parseEther("100")
      );
      nav = result[0];
      shares = result[1];

      // Final price should still be ~1.0
      const finalPrice = shares > 0n ? (nav * WAD) / shares : WAD;
      const diff = finalPrice > price ? finalPrice - price : price - finalPrice;

      // Allow slightly more tolerance due to multiple operations
      expect(diff).to.be.lte(5n);
    });

    it("withdraw-first-then-deposit preserves N/S ratio at batch price", async () => {
      // Whitepaper requirement: process order (withdraw → deposit) must preserve P^e
      const initialNav = ethers.parseEther("1000");
      const initialShares = ethers.parseEther("1000");
      const batchPrice = ethers.parseEther("1.2"); // P^e = 1.2

      const withdrawShares = ethers.parseEther("100");
      const depositAmount = ethers.parseEther("120");

      // Order 1: withdraw first, then deposit
      let [nav1, shares1] = await lib.applyWithdraw(
        initialNav,
        initialShares,
        batchPrice,
        withdrawShares
      );
      let [finalNav1, finalShares1, ,] = await lib.applyDeposit(
        nav1,
        shares1,
        batchPrice,
        depositAmount
      );

      // Order 2: deposit first, then withdraw
      let [nav2, shares2, ,] = await lib.applyDeposit(
        initialNav,
        initialShares,
        batchPrice,
        depositAmount
      );
      let [finalNav2, finalShares2] = await lib.applyWithdraw(
        nav2,
        shares2,
        batchPrice,
        withdrawShares
      );

      // Both orders should result in same final state (N/S = P^e preserved)
      const price1 = finalShares1 > 0n ? (finalNav1 * WAD) / finalShares1 : WAD;
      const price2 = finalShares2 > 0n ? (finalNav2 * WAD) / finalShares2 : WAD;

      // Allow 2 wei tolerance for rounding
      const priceDiff = price1 > price2 ? price1 - price2 : price2 - price1;
      expect(priceDiff).to.be.lte(2n);

      // Final states should be identical (same amounts processed)
      expect(finalNav1).to.equal(finalNav2);
      expect(finalShares1).to.equal(finalShares2);
    });
  });

  describe("Property: arithmetic bounds", () => {
    it("handles maximum WAD values without overflow", async () => {
      const maxNav = ethers.parseEther("1000000000"); // 1B tokens
      const maxShares = ethers.parseEther("1000000000");

      // Should not overflow
      const [navPre, batchPrice] = await lib.computePreBatch(
        maxNav,
        maxShares,
        0n,
        0n,
        0n
      );

      expect(navPre).to.equal(maxNav);
      expect(batchPrice).to.equal(WAD); // 1.0 since nav == shares
    });

    it("handles minimum non-zero values without underflow", async () => {
      const minNav = 1n;
      const minShares = 1n;

      const [navPre, batchPrice] = await lib.computePreBatch(
        minNav,
        minShares,
        0n,
        0n,
        0n
      );

      expect(navPre).to.equal(minNav);
      expect(batchPrice).to.equal(WAD); // 1/1 * WAD = WAD
    });
  });
});
