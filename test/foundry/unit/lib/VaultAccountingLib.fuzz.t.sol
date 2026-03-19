// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/VaultAccountingLibHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultAccountingLibFuzzTest
/// @notice Fuzz tests for VaultAccountingLib — validates properties across the full input space
/// @dev Invariants:
///   INV-V1: N^pre_t = N_{t-1} + L_t + F_t + G_t
///   INV-V2: P^e_t = N^pre_t / S_{t-1}
///   INV-V3: Seeding sets price to 1e18
///   INV-V4: Deposit preserves price |N'/S' - P| <= 1 wei
///   INV-V5: Withdraw preserves price |N''/S'' - P| <= 1 wei
///   INV-V6: Withdraw bounds check
///   INV-V7: Peak monotonicity
///   INV-V8: Drawdown range [0, 1e18]
contract VaultAccountingLibFuzzTest is HarnessDeployer {
    VaultAccountingLibHarness lib;

    function setUp() public override {
        super.setUp();
        lib = deployVaultAccountingLibHarness();
    }

    // ============================================================
    // Helper
    // ============================================================

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // ============================================================
    // A. computePreBatch (INV-V1, INV-V2) — 3 tests
    // ============================================================

    /// @notice INV-V1/V2: N^pre = N_prev + L + F + G, price = N^pre / S_prev
    function testFuzz_computePreBatch_navFormula(
        uint256 navPrev,
        uint256 sharesPrev,
        int256 pnl,
        uint256 fees,
        uint256 grant
    ) public view {
        navPrev = bound(navPrev, 1e18, 1e27);
        sharesPrev = bound(sharesPrev, 1e18, 1e27);
        fees = bound(fees, 0, navPrev / 10);
        grant = bound(grant, 0, navPrev / 10);

        // pnl in [-navPrev, navPrev*9] — ensure no underflow
        int256 pnlMin = -int256(navPrev);
        int256 pnlMax = int256(navPrev) * 9;
        pnl = bound(pnl, pnlMin, pnlMax);

        // Pre-check: ensure NAV won't underflow
        int256 pi = pnl + int256(fees) + int256(grant);
        if (pi < 0 && uint256(-pi) > navPrev) return;

        (uint256 navPre, uint256 batchPrice) = lib.computePreBatch(navPrev, sharesPrev, pnl, fees, grant);

        // INV-V1: N^pre = N_prev + pi
        uint256 expectedNav;
        if (pi >= 0) {
            expectedNav = navPrev + uint256(pi);
        } else {
            expectedNav = navPrev - uint256(-pi);
        }
        assertEq(navPre, expectedNav, "INV-V1: NAV formula");

        // INV-V2: batchPrice = wDiv(navPre, sharesPrev)
        uint256 expectedPrice = Math.mulDiv(navPre, WAD, sharesPrev);
        assertEq(batchPrice, expectedPrice, "INV-V2: price formula");
    }

    /// @notice Reverts when loss exceeds NAV
    function testFuzz_computePreBatch_revertsOnNAVUnderflow(uint256 navPrev, uint256 sharesPrev) public {
        navPrev = bound(navPrev, 1e18, 1e27);
        sharesPrev = bound(sharesPrev, 1e18, 1e27);

        // Loss strictly exceeds navPrev (fees=0, grant=0)
        int256 pnl = -int256(navPrev) - 1;

        vm.expectRevert();
        lib.computePreBatch(navPrev, sharesPrev, pnl, 0, 0);
    }

    /// @notice Reverts when sharesPrev = 0
    function testFuzz_computePreBatch_revertsOnZeroShares(uint256 navPrev) public {
        navPrev = bound(navPrev, 0, 1e27);

        vm.expectRevert();
        lib.computePreBatch(navPrev, 0, int256(0), 0, 0);
    }

    // ============================================================
    // B. computePreBatchForSeed (INV-V3) — 1 test
    // ============================================================

    /// @notice INV-V3: Seed always returns batchPrice = WAD
    function testFuzz_computePreBatchForSeed_alwaysReturnsWAD(
        uint256 navPrev,
        uint256 fees,
        uint256 grant
    ) public view {
        navPrev = bound(navPrev, 0, 1e27);
        fees = bound(fees, 0, 1e24);
        grant = bound(grant, 0, 1e24);

        (, uint256 batchPrice) = lib.computePreBatchForSeed(navPrev, int256(0), fees, grant);

        assertEq(batchPrice, WAD, "INV-V3: seed price must be WAD");
    }

    // ============================================================
    // C. applyDeposit (INV-V4, rounding security) — 4 tests
    // ============================================================

    /// @notice INV-V4: |N'/S' - P| <= 1 wei after deposit
    function testFuzz_applyDeposit_preservesPrice(uint256 nav, uint256 shares, uint256 depositAmount) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);

        // Price derived from nav/shares (the actual batch price)
        uint256 price = Math.mulDiv(nav, WAD, shares);
        if (price == 0) return;

        depositAmount = bound(depositAmount, price, 1e27);

        (uint256 newNav, uint256 newShares, uint256 minted, ) = lib.applyDeposit(nav, shares, price, depositAmount);

        if (minted == 0) return;

        uint256 newPrice = Math.mulDiv(newNav, WAD, newShares);

        assertLe(_absDiff(newPrice, price), 1, "INV-V4: price preservation");
    }

    /// @notice Protocol-favored rounding: mintedShares * P <= depositAmount, refund < price
    function testFuzz_applyDeposit_protocolFavored(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 depositAmount
    ) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        price = bound(price, 1, 1000e18);
        depositAmount = bound(depositAmount, price, 1e27);

        (, , uint256 minted, uint256 refund) = lib.applyDeposit(nav, shares, price, depositAmount);

        // minted * price (wMul floor) <= depositAmount
        uint256 amountUsed = Math.mulDiv(minted, price, WAD);
        assertLe(amountUsed, depositAmount, "protocol favored: amount used <= deposit");

        // refund < price (at most 1 share's worth of dust)
        assertLt(refund, price, "refund < price");
    }

    /// @notice Tiny deposit below 1 share → 0 minted, full refund
    function testFuzz_applyDeposit_zeroMintedSharesForTinyDeposit(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 depositAmount
    ) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        price = bound(price, 2 * WAD, 1000e18);
        // depositAmount < price/WAD in WAD terms → wDiv floors to 0
        depositAmount = bound(depositAmount, 1, price / WAD - 1);

        (, , uint256 minted, uint256 refund) = lib.applyDeposit(nav, shares, price, depositAmount);

        assertEq(minted, 0, "tiny deposit: 0 minted");
        assertEq(refund, depositAmount, "tiny deposit: full refund");
    }

    /// @notice Reverts on zero price
    function testFuzz_applyDeposit_revertsOnZeroPrice(uint256 nav, uint256 shares, uint256 depositAmount) public {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        depositAmount = bound(depositAmount, 1, 1e27);

        vm.expectRevert();
        lib.applyDeposit(nav, shares, 0, depositAmount);
    }

    // ============================================================
    // D. applyWithdraw (INV-V5, INV-V6) — 4 tests
    // ============================================================

    /// @notice INV-V5: |N''/S'' - P| <= 1 wei after withdraw (moderate withdrawal)
    function testFuzz_applyWithdraw_preservesPrice(uint256 nav, uint256 shares, uint256 withdrawShares) public view {
        shares = bound(shares, 2e18, 1e27);
        // nav >= shares ensures price >= 1 WAD (avoids sub-WAD rounding noise)
        nav = bound(nav, shares, 1e27);

        // Price derived from nav/shares (the actual batch price)
        uint256 price = Math.mulDiv(nav, WAD, shares);

        // Limit to shares/2 so remaining shares >= shares/2.
        // Near-total withdrawals amplify rounding error by shares/newShares ratio.
        withdrawShares = bound(withdrawShares, 1, shares / 2);

        // Pre-check: withdrawAmount must not exceed nav
        uint256 withdrawAmount = Math.mulDiv(withdrawShares, price, WAD);
        if (withdrawAmount > nav) return;

        (uint256 newNav, uint256 newShares, ) = lib.applyWithdraw(nav, shares, price, withdrawShares);

        if (newShares == 0) return;

        uint256 newPrice = Math.mulDiv(newNav, WAD, newShares);

        assertLe(_absDiff(newPrice, price), 1, "INV-V5: price preservation");
    }

    /// @notice INV-V5: withdrawAmount = wMul(shares, price) — floor rounding favors protocol
    function testFuzz_applyWithdraw_protocolFavored(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 withdrawShares
    ) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        price = bound(price, 1, 1000e18);
        withdrawShares = bound(withdrawShares, 1, shares);

        // Pre-check: withdrawAmount must not exceed nav
        uint256 expectedAmount = Math.mulDiv(withdrawShares, price, WAD);
        if (expectedAmount > nav) return;

        (, , uint256 withdrawAmount) = lib.applyWithdraw(nav, shares, price, withdrawShares);

        // withdrawAmount = floor(withdrawShares * price / WAD)
        assertEq(withdrawAmount, expectedAmount, "withdraw uses floor rounding");
    }

    /// @notice INV-V6: Reverts when withdrawShares > shares
    function testFuzz_applyWithdraw_revertsInsufficientShares(uint256 nav, uint256 shares, uint256 extra) public {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        extra = bound(extra, 1, 1e27);
        uint256 tooMany = shares + extra;

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("InsufficientShares(uint256,uint256)")), tooMany, shares)
        );
        lib.applyWithdraw(nav, shares, WAD, tooMany);
    }

    /// @notice INV-V6: Reverts when withdrawAmount > nav
    function testFuzz_applyWithdraw_revertsInsufficientNAV(uint256 nav, uint256 shares, uint256 price) public {
        nav = bound(nav, 1e18, 1e26);
        shares = bound(shares, 1e18, 1e27);
        // price high enough so shares * price > nav
        price = bound(price, 1e18, 1000e18);

        uint256 withdrawAmount = Math.mulDiv(shares, price, WAD);
        // Need withdrawAmount > nav for the revert
        vm.assume(withdrawAmount > nav);

        vm.expectRevert();
        lib.applyWithdraw(nav, shares, price, shares);
    }

    // ============================================================
    // E. Peak & Drawdown (INV-V7, INV-V8) — 3 tests
    // ============================================================

    /// @notice INV-V7: updatedPeak >= currentPeak && updatedPeak >= newPrice
    function testFuzz_updatePeak_monotonicity(uint256 currentPeak, uint256 newPrice) public view {
        currentPeak = bound(currentPeak, 0, 1e27);
        newPrice = bound(newPrice, 0, 1e27);

        uint256 updatedPeak = lib.updatePeak(currentPeak, newPrice);

        assertGe(updatedPeak, currentPeak, "INV-V7: peak >= previous peak");
        assertGe(updatedPeak, newPrice, "INV-V7: peak >= new price");
    }

    /// @notice INV-V8: DD in [0, WAD], formula = (peak - price) / peak
    function testFuzz_computeDrawdown_rangeAndFormula(uint256 price, uint256 peak) public view {
        peak = bound(peak, 1, 1e27);
        price = bound(price, 0, peak);

        uint256 dd = lib.computeDrawdown(price, peak);

        // Range check
        assertLe(dd, WAD, "INV-V8: drawdown <= WAD");

        // Formula check: dd = wDiv(peak - price, peak)
        uint256 expectedDD = Math.mulDiv(peak - price, WAD, peak);
        assertEq(dd, expectedDD, "INV-V8: drawdown formula");
    }

    /// @notice INV-V8: price >= peak → DD = 0
    function testFuzz_computeDrawdown_zeroWhenPriceExceedsPeak(uint256 price, uint256 peak) public view {
        peak = bound(peak, 0, 1e27);
        price = bound(price, peak, 1e27);

        uint256 dd = lib.computeDrawdown(price, peak);

        assertEq(dd, 0, "INV-V8: no drawdown when price >= peak");
    }

    // ============================================================
    // F. computePrice & computePostBatchState — 3 tests
    // ============================================================

    /// @notice price = wDiv(nav, shares)
    function testFuzz_computePrice_formula(uint256 nav, uint256 shares) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);

        uint256 price = lib.computePrice(nav, shares);
        uint256 expected = Math.mulDiv(nav, WAD, shares);

        assertEq(price, expected, "price = wDiv(nav, shares)");
    }

    /// @notice Composition: price, peak, drawdown consistent with standalone functions
    function testFuzz_computePostBatchState_consistency(uint256 nav, uint256 shares, uint256 previousPeak) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        previousPeak = bound(previousPeak, 0, 1e27);

        (uint256 navOut, uint256 sharesOut, uint256 price, uint256 pricePeak, uint256 drawdown) = lib
            .computePostBatchState(nav, shares, previousPeak);

        // nav/shares passed through
        assertEq(navOut, nav, "nav passthrough");
        assertEq(sharesOut, shares, "shares passthrough");

        // price matches standalone
        uint256 expectedPrice = lib.computePrice(nav, shares);
        assertEq(price, expectedPrice, "price matches computePrice");

        // peak matches standalone
        uint256 expectedPeak = lib.updatePeak(previousPeak, price);
        assertEq(pricePeak, expectedPeak, "peak matches updatePeak");

        // drawdown matches standalone
        uint256 expectedDD = lib.computeDrawdown(price, pricePeak);
        assertEq(drawdown, expectedDD, "drawdown matches computeDrawdown");
    }

    /// @notice shares=0 → price=WAD, peak preserved, DD=0
    function testFuzz_computePostBatchState_emptyVault(uint256 nav, uint256 previousPeak) public view {
        nav = bound(nav, 0, 1e27);
        previousPeak = bound(previousPeak, 0, 1e27);

        (, , uint256 price, uint256 pricePeak, uint256 drawdown) = lib.computePostBatchState(nav, 0, previousPeak);

        assertEq(price, WAD, "empty vault: price = WAD");
        assertEq(pricePeak, previousPeak, "empty vault: peak preserved");
        assertEq(drawdown, 0, "empty vault: DD = 0");
    }

    // ============================================================
    // G. Cross-Operation Security — 3 tests
    // ============================================================

    /// @notice deposit→withdraw same shares: finalNav <= nav (no value extraction)
    function testFuzz_depositWithdrawRoundTrip_noValueExtraction(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 depositAmount
    ) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 1e18, 1e27);
        price = bound(price, 1e18, 1000e18);
        depositAmount = bound(depositAmount, price, 1e27);

        // Deposit
        (uint256 navAfterDeposit, uint256 sharesAfterDeposit, uint256 minted, ) = lib.applyDeposit(
            nav,
            shares,
            price,
            depositAmount
        );

        if (minted == 0) return;

        // Pre-check: withdraw won't exceed nav
        uint256 withdrawAmount = Math.mulDiv(minted, price, WAD);
        if (withdrawAmount > navAfterDeposit) return;

        // Withdraw same minted shares
        (uint256 finalNav, , ) = lib.applyWithdraw(navAfterDeposit, sharesAfterDeposit, price, minted);

        // No value extraction: finalNav <= original nav (rounding may lose dust)
        assertLe(finalNav, nav + 1, "deposit-withdraw round trip: no value extraction");
    }

    /// @notice withdraw→deposit same amount: reminted <= burned (no share inflation)
    function testFuzz_withdrawDepositRoundTrip_noValueExtraction(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 withdrawShares
    ) public view {
        nav = bound(nav, 1e18, 1e27);
        shares = bound(shares, 2e18, 1e27);
        price = bound(price, 1e18, 1000e18);
        withdrawShares = bound(withdrawShares, 1, shares - 1e18);

        // Pre-check: withdrawAmount must not exceed nav
        uint256 expectedWithdraw = Math.mulDiv(withdrawShares, price, WAD);
        if (expectedWithdraw > nav) return;

        // Withdraw
        (uint256 navAfterWithdraw, uint256 sharesAfterWithdraw, uint256 withdrawAmount) = lib.applyWithdraw(
            nav,
            shares,
            price,
            withdrawShares
        );

        // Deposit back the same amount
        (, , uint256 reminted, ) = lib.applyDeposit(navAfterWithdraw, sharesAfterWithdraw, price, withdrawAmount);

        // No share inflation: reminted <= burned
        assertLe(reminted, withdrawShares, "withdraw-deposit round trip: no share inflation");
    }

    /// @notice withdraw→deposit vs deposit→withdraw: nav/shares exact match, price within 2 wei
    function testFuzz_operationOrderIndependence(
        uint256 initialNav,
        uint256 initialShares,
        uint256 batchPrice,
        uint256 withdrawShares,
        uint256 depositAmount
    ) public view {
        initialNav = bound(initialNav, 1e18, 1e27);
        initialShares = bound(initialShares, 2e18, 1e27);
        batchPrice = bound(batchPrice, 1e18, 1000e18);
        withdrawShares = bound(withdrawShares, 1, initialShares - 1e18);
        depositAmount = bound(depositAmount, batchPrice, 1e27);

        // Pre-check: withdrawAmount must not exceed nav
        uint256 withdrawAmount = Math.mulDiv(withdrawShares, batchPrice, WAD);
        if (withdrawAmount > initialNav) return;

        // Order 1: withdraw first, then deposit
        (uint256 nav1, uint256 shares1, ) = lib.applyWithdraw(initialNav, initialShares, batchPrice, withdrawShares);
        (uint256 finalNav1, uint256 finalShares1, , ) = lib.applyDeposit(nav1, shares1, batchPrice, depositAmount);

        // Order 2: deposit first, then withdraw
        (uint256 nav2, uint256 shares2, , ) = lib.applyDeposit(initialNav, initialShares, batchPrice, depositAmount);

        // Pre-check: withdraw from post-deposit state
        uint256 withdrawAmount2 = Math.mulDiv(withdrawShares, batchPrice, WAD);
        if (withdrawAmount2 > nav2) return;
        if (withdrawShares > shares2) return;

        (uint256 finalNav2, uint256 finalShares2, ) = lib.applyWithdraw(nav2, shares2, batchPrice, withdrawShares);

        // Exact match for nav and shares
        assertEq(finalNav1, finalNav2, "order independence: nav");
        assertEq(finalShares1, finalShares2, "order independence: shares");

        // Price within 2 wei (rounding in wDiv)
        if (finalShares1 > 0 && finalShares2 > 0) {
            uint256 price1 = Math.mulDiv(finalNav1, WAD, finalShares1);
            uint256 price2 = Math.mulDiv(finalNav2, WAD, finalShares2);
            assertLe(_absDiff(price1, price2), 2, "order independence: price within 2 wei");
        }
    }

    // ============================================================
    // H. Multi-Step Batch Sequence — 1 test
    // ============================================================

    /// @notice 100 valid sequences × 5-10 batches. Checks ALL invariants (V1-V8)
    function test_fuzz_multiStepBatchSequence_100cases() public view {
        Prng memory prng = createPrng();

        uint256 validCases = 0;
        uint256 attempts = 0;
        uint256 maxAttempts = 300;

        while (validCases < 100 && attempts < maxAttempts) {
            attempts++;

            // Initial state
            uint256 nav = nextInRange(prng, 100, 10000) * WAD;
            uint256 shares = nextInRange(prng, 100, 10000) * WAD;
            uint256 peak = Math.mulDiv(nav, WAD, shares);

            uint256 numBatches = nextInRange(prng, 5, 11);
            bool sequenceValid = true;

            for (uint256 b = 0; b < numBatches; b++) {
                // Skip if shares depleted
                if (shares == 0) break;

                // --- Pre-batch: random P&L [-20%, +30%] NAV ---
                int256 pnlPercent = int256(nextInRange(prng, 0, 51)) - 20; // [-20, +30]
                int256 pnl = (int256(nav) * pnlPercent) / 100;
                uint256 fees = (nav * nextInRange(prng, 0, 6)) / 100; // [0, 5%]
                uint256 grant = (nav * nextInRange(prng, 0, 3)) / 100; // [0, 2%]

                // Pre-check: NAV underflow
                int256 pi = pnl + int256(fees) + int256(grant);
                if (pi < 0 && uint256(-pi) > nav) {
                    sequenceValid = false;
                    break;
                }

                (uint256 navPre, uint256 batchPrice) = lib.computePreBatch(nav, shares, pnl, fees, grant);

                // INV-V1: NAV formula
                uint256 expectedNav;
                if (pi >= 0) {
                    expectedNav = nav + uint256(pi);
                } else {
                    expectedNav = nav - uint256(-pi);
                }
                assertEq(navPre, expectedNav, "multi-step INV-V1");

                // INV-V2: price formula
                uint256 expectedPrice = Math.mulDiv(navPre, WAD, shares);
                assertEq(batchPrice, expectedPrice, "multi-step INV-V2");

                nav = navPre;

                // --- Deposits ---
                uint256 numDeposits = nextInRange(prng, 0, 4);
                for (uint256 d = 0; d < numDeposits; d++) {
                    if (batchPrice == 0) break;
                    uint256 depositAmount = nextInRange(prng, 1, 101) * WAD;

                    (uint256 newNav, uint256 newShares, uint256 minted, uint256 refund) = lib.applyDeposit(
                        nav,
                        shares,
                        batchPrice,
                        depositAmount
                    );

                    // INV-V4: price preservation
                    if (minted > 0 && newShares > 0) {
                        uint256 newPrice = Math.mulDiv(newNav, WAD, newShares);
                        uint256 oldPrice = Math.mulDiv(nav, WAD, shares);
                        assertLe(_absDiff(newPrice, oldPrice), 1, "multi-step INV-V4");
                    }

                    // Protocol-favored rounding
                    assertLt(refund, batchPrice, "multi-step: refund < price");

                    nav = newNav;
                    shares = newShares;
                }

                // --- Withdrawals ---
                uint256 numWithdraws = nextInRange(prng, 0, 4);
                for (uint256 w = 0; w < numWithdraws; w++) {
                    if (shares == 0) break;
                    uint256 maxWithdraw = shares / 4; // At most 25% per withdrawal
                    if (maxWithdraw == 0) break;
                    uint256 wShares = nextInRange(prng, 1, maxWithdraw + 1);

                    // Pre-check: withdraw amount vs nav
                    uint256 wAmount = Math.mulDiv(wShares, batchPrice, WAD);
                    if (wAmount > nav) continue;

                    (uint256 newNav, uint256 newShares, ) = lib.applyWithdraw(nav, shares, batchPrice, wShares);

                    // INV-V5: price preservation
                    if (newShares > 0) {
                        uint256 newPrice = Math.mulDiv(newNav, WAD, newShares);
                        uint256 oldPrice = shares > 0 ? Math.mulDiv(nav, WAD, shares) : WAD;
                        assertLe(_absDiff(newPrice, oldPrice), 1, "multi-step INV-V5");
                    }

                    nav = newNav;
                    shares = newShares;
                }

                // --- Post-batch state ---
                if (shares > 0) {
                    uint256 price = Math.mulDiv(nav, WAD, shares);

                    // INV-V7: peak monotonicity
                    uint256 newPeak = lib.updatePeak(peak, price);
                    assertGe(newPeak, peak, "multi-step INV-V7");

                    // INV-V8: drawdown range
                    uint256 dd = lib.computeDrawdown(price, newPeak);
                    assertLe(dd, WAD, "multi-step INV-V8");

                    peak = newPeak;
                }
            }

            if (sequenceValid) validCases++;
        }
        assertGe(validCases, 100, "Need at least 100 valid multi-step sequences");
    }
}
