// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/VaultAccountingLibHarness.sol";

/// @title VaultAccountingLibTest
/// @notice Foundry port of vaultAccountingLib.spec.ts
/// @dev Invariants:
///   INV-V1: N^pre_t = N_{t-1} + L_t + F_t + G_t
///   INV-V2: P^e_t = N^pre_t / S_{t-1}
///   INV-V3: Seeding sets price to 1e18
///   INV-V4: Deposit preserves price |N'/S' - P| <= 1 wei
///   INV-V5: Withdraw preserves price |N''/S'' - P| <= 1 wei
///   INV-V6: Withdraw bounds check
///   INV-V7: Peak monotonicity
///   INV-V8: Drawdown range [0, 1e18]
contract VaultAccountingLibTest is HarnessDeployer {
    VaultAccountingLibHarness lib;

    function setUp() public override {
        super.setUp();
        lib = deployVaultAccountingLibHarness();
    }

    // ============================================================
    // INV-V1: Pre-batch NAV calculation
    // N_pre,t = N_{t-1} + L_t + F_t + G_t
    // ============================================================

    function test_INVV1_computePreBatch_calculates_preBatchNav() public view {
        uint256 navPrev = 1000e18;
        uint256 sharesPrev = 900e18;
        int256 pnl = -50e18;
        uint256 fees = 30e18;
        uint256 grant = 10e18;

        (uint256 navPre,) = lib.computePreBatch(navPrev, sharesPrev, pnl, fees, grant);

        // N_pre = 1000 - 50 + 30 + 10 = 990
        assertEq(navPre, 990e18);
    }

    function test_INVV1_computePreBatch_handles_positive_pnl() public view {
        uint256 navPrev = 1000e18;
        uint256 sharesPrev = 1000e18;
        int256 pnl = 100e18;
        uint256 fees = 20e18;
        uint256 grant = 0;

        (uint256 navPre,) = lib.computePreBatch(navPrev, sharesPrev, pnl, fees, grant);

        // N_pre = 1000 + 100 + 20 + 0 = 1120
        assertEq(navPre, 1120e18);
    }

    function test_INVV1_computePreBatch_handles_zero_inputs() public view {
        uint256 navPrev = 1000e18;
        uint256 sharesPrev = 1000e18;

        (uint256 navPre,) = lib.computePreBatch(navPrev, sharesPrev, int256(0), 0, 0);

        assertEq(navPre, navPrev);
    }

    function test_INVV1_computePreBatch_reverts_NAVUnderflow() public {
        uint256 navPrev = 100e18;
        uint256 sharesPrev = 100e18;
        int256 pnl = -200e18; // loss > nav

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("NAVUnderflow(uint256,uint256)")), navPrev, 200e18));
        lib.computePreBatch(navPrev, sharesPrev, pnl, 0, 0);
    }

    // ============================================================
    // INV-V2: Batch price calculation
    // P_e,t = N_pre,t / S_{t-1}
    // ============================================================

    function test_INVV2_computePreBatch_calculates_batchPrice() public view {
        uint256 navPrev = 1000e18;
        uint256 sharesPrev = 900e18;

        (uint256 navPre, uint256 batchPrice) = lib.computePreBatch(navPrev, sharesPrev, int256(0), 0, 0);

        // P_e = 1000 / 900
        uint256 expectedPrice = (navPre * WAD) / sharesPrev;
        assertEq(batchPrice, expectedPrice);
    }

    function test_INVV2_computePreBatch_high_precision_division() public view {
        uint256 navPrev = 990e18;
        uint256 sharesPrev = 900e18;

        (, uint256 batchPrice) = lib.computePreBatch(navPrev, sharesPrev, int256(0), 0, 0);

        // P_e = 990 / 900 = 1.1e18
        assertEq(batchPrice, 1.1e18);
    }

    function test_INVV2_computePreBatch_reverts_zero_shares() public {
        uint256 navPrev = 1000e18;

        vm.expectRevert();
        lib.computePreBatch(navPrev, 0, int256(0), 0, 0);
    }

    // ============================================================
    // INV-V3: Seeding (shares=0 initialization)
    // ============================================================

    function test_INVV3_seed_sets_initial_price_to_WAD() public view {
        (, uint256 batchPrice) = lib.computePreBatchForSeed(0, int256(0), 0, 0);

        assertEq(batchPrice, WAD);
    }

    function test_INVV3_seed_handles_nonzero_initial_nav() public view {
        (uint256 navPre, uint256 batchPrice) = lib.computePreBatchForSeed(100e18, int256(0), 0, 0);

        assertEq(navPre, 100e18);
        assertEq(batchPrice, WAD);
    }

    // ============================================================
    // INV-V4: Deposit price preservation
    // S_mint = floor(A/P), A_used = S_mint * P
    // N' = N + A_used, S' = S + S_mint, refund = A - A_used
    // ============================================================

    function test_INVV4_applyDeposit_increases_nav_and_shares() public view {
        uint256 nav = 1000e18;
        uint256 shares = 1000e18;
        uint256 price = 1e18;
        uint256 deposit = 100e18;

        (uint256 newNav, uint256 newShares, uint256 minted, uint256 refund) =
            lib.applyDeposit(nav, shares, price, deposit);

        assertEq(newNav, 1100e18);
        assertEq(minted, 100e18);
        assertEq(newShares, 1100e18);
        assertEq(refund, 0);
    }

    function test_INVV4_applyDeposit_preserves_price_within_1_wei() public view {
        uint256 nav = 1000e18;
        uint256 shares = 900e18;
        uint256 price = (nav * WAD) / shares; // ~1.111e18
        uint256 deposit = 100e18;

        (uint256 newNav, uint256 newShares,, uint256 refund) = lib.applyDeposit(nav, shares, price, deposit);

        uint256 newPrice = (newNav * WAD) / newShares;

        // Price preservation: |newPrice - price| <= 1 wei
        uint256 diff = newPrice > price ? newPrice - price : price - newPrice;
        assertLe(diff, 1);

        // Refund should be small
        assertLe(refund, 1);
    }

    function test_INVV4_applyDeposit_handles_large_deposit() public view {
        uint256 nav = 1000e18;
        uint256 shares = 1000e18;
        uint256 price = 1e18;
        uint256 deposit = 1_000_000e18;

        (uint256 newNav, uint256 newShares,, uint256 refund) = lib.applyDeposit(nav, shares, price, deposit);

        assertEq(newNav, 1_001_000e18);
        assertEq(newShares, 1_001_000e18);
        assertEq(refund, 0);
    }

    function test_INVV4_applyDeposit_reverts_zero_price() public {
        vm.expectRevert();
        lib.applyDeposit(WAD, WAD, 0, WAD);
    }

    function test_INVV4_applyDeposit_refunds_dust() public view {
        // Use a price that doesn't divide evenly
        uint256 nav = 1000e18;
        uint256 shares = 700e18; // Price = 1000/700 ~ 1.4285...
        uint256 price = (nav * WAD) / shares;
        uint256 deposit = 100e18;

        (uint256 newNav,, uint256 minted, uint256 refund) = lib.applyDeposit(nav, shares, price, deposit);

        // A_used = minted * price / WAD
        uint256 amountUsed = (minted * price) / WAD;

        // newNav = nav + A_used
        assertEq(newNav, nav + amountUsed);

        // refund = deposit - A_used
        assertEq(refund, deposit - amountUsed);

        // refund < price
        assertLt(refund, price);
    }

    // ============================================================
    // INV-V5: Withdraw price preservation
    // After withdraw x: N'' = N - x*P, S'' = S - x, |N''/S'' - P| <= 1 wei
    // ============================================================

    function test_INVV5_applyWithdraw_decreases_nav_and_shares() public view {
        uint256 nav = 1000e18;
        uint256 shares = 1000e18;
        uint256 price = 1e18;
        uint256 withdrawShares = 50e18;

        (uint256 newNav, uint256 newShares, uint256 withdrawAmount) =
            lib.applyWithdraw(nav, shares, price, withdrawShares);

        assertEq(newNav, 950e18);
        assertEq(newShares, 950e18);
        assertEq(withdrawAmount, 50e18);
    }

    function test_INVV5_applyWithdraw_preserves_price_within_1_wei() public view {
        uint256 nav = 1100e18;
        uint256 shares = 1000e18;
        uint256 price = (nav * WAD) / shares; // 1.1e18
        uint256 withdrawShares = 100e18;

        (uint256 newNav, uint256 newShares,) = lib.applyWithdraw(nav, shares, price, withdrawShares);

        uint256 newPrice = newShares > 0 ? (newNav * WAD) / newShares : WAD;

        uint256 diff = newPrice > price ? newPrice - price : price - newPrice;
        assertLe(diff, 1);
    }

    function test_INVV5_applyWithdraw_full_withdrawal() public view {
        uint256 nav = 1000e18;
        uint256 shares = 1000e18;
        uint256 price = 1e18;

        (uint256 newNav, uint256 newShares, uint256 withdrawAmount) = lib.applyWithdraw(nav, shares, price, shares);

        assertEq(newNav, 0);
        assertEq(newShares, 0);
        assertEq(withdrawAmount, nav);
    }

    // ============================================================
    // INV-V6: Withdraw bounds
    // ============================================================

    function test_INVV6_applyWithdraw_reverts_insufficient_shares() public {
        uint256 nav = 1000e18;
        uint256 shares = 1000e18;
        uint256 price = 1e18;
        uint256 tooMany = 1001e18;

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("InsufficientShares(uint256,uint256)")), tooMany, shares)
        );
        lib.applyWithdraw(nav, shares, price, tooMany);
    }

    function test_INVV6_applyWithdraw_reverts_insufficient_nav() public {
        // price * shares > nav due to rounding
        uint256 nav = 99e18;
        uint256 shares = 100e18;
        uint256 price = 1e18;
        uint256 withdrawShares = 100e18;

        vm.expectRevert();
        lib.applyWithdraw(nav, shares, price, withdrawShares);
    }

    // ============================================================
    // INV-V7: Peak monotonicity
    // P_peak,t >= P_peak,{t-1}
    // ============================================================

    function test_INVV7_updatePeak_updates_when_price_exceeds() public view {
        uint256 currentPeak = 1e18;
        uint256 newPrice = 1.2e18;

        uint256 updatedPeak = lib.updatePeak(currentPeak, newPrice);

        assertEq(updatedPeak, newPrice);
    }

    function test_INVV7_updatePeak_keeps_when_price_is_lower() public view {
        uint256 currentPeak = 1.2e18;
        uint256 newPrice = 1e18;

        uint256 updatedPeak = lib.updatePeak(currentPeak, newPrice);

        assertEq(updatedPeak, currentPeak);
    }

    function test_INVV7_updatePeak_handles_equal() public view {
        uint256 currentPeak = 1e18;
        uint256 newPrice = 1e18;

        uint256 updatedPeak = lib.updatePeak(currentPeak, newPrice);

        assertEq(updatedPeak, currentPeak);
    }

    function test_INVV7_updatePeak_sequence_maintains_monotonicity() public view {
        uint256[6] memory prices = [uint256(1e18), 1.2e18, 1.1e18, 1.3e18, 0.9e18, 1.5e18];
        uint256 peak = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 newPeak = lib.updatePeak(peak, prices[i]);
            assertGe(newPeak, peak);
            peak = newPeak;
        }

        assertEq(peak, 1.5e18);
    }

    // ============================================================
    // INV-V8: Peak drawdown range [0, 1e18]
    // DD_t = 1 - P_t / P_peak,t
    // ============================================================

    function test_INVV8_computeDrawdown_zero_when_price_equals_peak() public view {
        uint256 price = 1e18;
        uint256 peak = 1e18;

        uint256 dd = lib.computeDrawdown(price, peak);

        assertEq(dd, 0);
    }

    function test_INVV8_computeDrawdown_20_percent() public view {
        uint256 price = 0.8e18;
        uint256 peak = 1e18;

        uint256 dd = lib.computeDrawdown(price, peak);

        // DD = 1 - 0.8/1.0 = 0.2
        assertEq(dd, 0.2e18);
    }

    function test_INVV8_computeDrawdown_100_percent_when_price_zero() public view {
        uint256 price = 0;
        uint256 peak = 1e18;

        uint256 dd = lib.computeDrawdown(price, peak);

        assertEq(dd, 1e18);
    }

    function test_INVV8_computeDrawdown_zero_when_peak_zero() public view {
        uint256 dd = lib.computeDrawdown(0, 0);

        assertEq(dd, 0);
    }

    function test_INVV8_computeDrawdown_zero_when_price_exceeds_peak() public view {
        uint256 price = 1.2e18;
        uint256 peak = 1e18;

        uint256 dd = lib.computeDrawdown(price, peak);

        assertEq(dd, 0);
    }

    function test_INVV8_computeDrawdown_small_precision() public view {
        uint256 peak = 1e18;
        uint256 price = 0.999e18; // 0.1% drawdown

        uint256 dd = lib.computeDrawdown(price, peak);

        // DD = 0.001 = 1e15
        assertEq(dd, 0.001e18);
    }

    // ============================================================
    // computePrice
    // ============================================================

    function test_computePrice_normal_case() public view {
        uint256 nav = 1000e18;
        uint256 shares = 900e18;

        uint256 price = lib.computePrice(nav, shares);

        uint256 expected = (nav * WAD) / shares;
        assertEq(price, expected);
    }

    function test_computePrice_returns_WAD_when_shares_zero() public view {
        uint256 price = lib.computePrice(100e18, 0);

        assertEq(price, WAD);
    }

    function test_computePrice_returns_WAD_when_both_zero() public view {
        uint256 price = lib.computePrice(0, 0);

        assertEq(price, WAD);
    }

    function test_computePrice_returns_zero_when_nav_zero() public view {
        uint256 price = lib.computePrice(0, 100e18);

        assertEq(price, 0);
    }

    // ============================================================
    // computePostBatchState
    // ============================================================

    function test_computePostBatchState_complete() public view {
        uint256 nav = 1100e18;
        uint256 shares = 1000e18;
        uint256 previousPeak = 1e18;

        (uint256 navOut, uint256 sharesOut, uint256 price, uint256 pricePeak, uint256 drawdown) =
            lib.computePostBatchState(nav, shares, previousPeak);

        assertEq(navOut, nav);
        assertEq(sharesOut, shares);
        assertEq(price, 1.1e18);
        assertEq(pricePeak, 1.1e18); // New peak
        assertEq(drawdown, 0); // At peak, no drawdown
    }

    function test_computePostBatchState_tracks_drawdown() public view {
        uint256 nav = 900e18;
        uint256 shares = 1000e18;
        uint256 previousPeak = 1.2e18;

        (,, uint256 price, uint256 pricePeak, uint256 drawdown) = lib.computePostBatchState(nav, shares, previousPeak);

        assertEq(price, 0.9e18);
        assertEq(pricePeak, previousPeak); // Peak unchanged
        // DD = 1 - 0.9/1.2 = 0.25
        assertEq(drawdown, 0.25e18);
    }

    function test_computePostBatchState_empty_vault() public view {
        uint256 nav = 0;
        uint256 shares = 0;
        uint256 previousPeak = 1.5e18;

        (uint256 navOut, uint256 sharesOut, uint256 price, uint256 pricePeak, uint256 drawdown) =
            lib.computePostBatchState(nav, shares, previousPeak);

        assertEq(navOut, 0);
        assertEq(sharesOut, 0);
        assertEq(price, WAD); // empty vault defaults to 1.0
        assertEq(pricePeak, previousPeak); // preserved
        assertEq(drawdown, 0); // no active LP exposure
    }

    // ============================================================
    // Property: price preservation round-trip
    // ============================================================

    function test_property_deposit_then_withdraw_preserves_state() public view {
        uint256 initialNav = 1000e18;
        uint256 initialShares = 1000e18;
        uint256 price = 1e18;
        uint256 amount = 100e18;

        // Deposit
        (uint256 navAfterDeposit, uint256 sharesAfterDeposit, uint256 minted,) =
            lib.applyDeposit(initialNav, initialShares, price, amount);

        // Withdraw same shares
        (uint256 finalNav, uint256 finalShares,) = lib.applyWithdraw(navAfterDeposit, sharesAfterDeposit, price, minted);

        // Should return to initial state (within rounding)
        uint256 navDiff = finalNav > initialNav ? finalNav - initialNav : initialNav - finalNav;
        uint256 sharesDiff = finalShares > initialShares ? finalShares - initialShares : initialShares - finalShares;

        assertLe(navDiff, 1);
        assertEq(sharesDiff, 0);
    }

    function test_property_multiple_deposits_withdraws_preserve_price() public view {
        uint256 nav = 1000e18;
        uint256 shares = 1000e18;
        uint256 price = 1e18;

        // Deposit 50
        (nav, shares,,) = lib.applyDeposit(nav, shares, price, 50e18);

        // Deposit 30
        (nav, shares,,) = lib.applyDeposit(nav, shares, price, 30e18);

        // Withdraw 20
        (nav, shares,) = lib.applyWithdraw(nav, shares, price, 20e18);

        // Deposit 100
        (nav, shares,,) = lib.applyDeposit(nav, shares, price, 100e18);

        // Final price should still be ~1.0
        uint256 finalPrice = shares > 0 ? (nav * WAD) / shares : WAD;
        uint256 diff = finalPrice > price ? finalPrice - price : price - finalPrice;

        assertLe(diff, 5);
    }

    function test_property_withdraw_first_then_deposit_preserves_price() public view {
        uint256 initialNav = 1000e18;
        uint256 initialShares = 1000e18;
        uint256 batchPrice = 1.2e18;

        uint256 withdrawShares = 100e18;
        uint256 depositAmount = 120e18;

        // Order 1: withdraw first, then deposit
        (uint256 nav1, uint256 shares1,) = lib.applyWithdraw(initialNav, initialShares, batchPrice, withdrawShares);
        (uint256 finalNav1, uint256 finalShares1,,) = lib.applyDeposit(nav1, shares1, batchPrice, depositAmount);

        // Order 2: deposit first, then withdraw
        (uint256 nav2, uint256 shares2,,) = lib.applyDeposit(initialNav, initialShares, batchPrice, depositAmount);
        (uint256 finalNav2, uint256 finalShares2,) = lib.applyWithdraw(nav2, shares2, batchPrice, withdrawShares);

        // Both orders should result in same final price (within 2 wei)
        uint256 price1 = finalShares1 > 0 ? (finalNav1 * WAD) / finalShares1 : WAD;
        uint256 price2 = finalShares2 > 0 ? (finalNav2 * WAD) / finalShares2 : WAD;

        uint256 priceDiff = price1 > price2 ? price1 - price2 : price2 - price1;
        assertLe(priceDiff, 2);

        // Final states should be identical
        assertEq(finalNav1, finalNav2);
        assertEq(finalShares1, finalShares2);
    }

    // ============================================================
    // Property: arithmetic bounds
    // ============================================================

    function test_property_max_wad_values_no_overflow() public view {
        uint256 maxNav = 1_000_000_000e18;
        uint256 maxShares = 1_000_000_000e18;

        (uint256 navPre, uint256 batchPrice) = lib.computePreBatch(maxNav, maxShares, int256(0), 0, 0);

        assertEq(navPre, maxNav);
        assertEq(batchPrice, WAD); // 1.0 since nav == shares
    }

    function test_property_min_nonzero_values_no_underflow() public view {
        uint256 minNav = 1;
        uint256 minShares = 1;

        (uint256 navPre, uint256 batchPrice) = lib.computePreBatch(minNav, minShares, int256(0), 0, 0);

        assertEq(navPre, minNav);
        assertEq(batchPrice, WAD); // 1/1 * WAD = WAD
    }
}
