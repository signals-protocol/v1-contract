// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/FixedPointMathHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract FixedPointMathPrecisionTest is HarnessDeployer {
    FixedPointMathHarness h;

    // Maximum allowed relative error: 1e-6 (0.0001%)
    uint256 constant MAX_RELATIVE_ERROR = WAD / 1_000_000; // 1e12

    // Reference values: ln(x) * 1e18 (high precision ground truth)
    uint256 constant LN_2 = 693147180559945309;
    uint256 constant LN_10 = 2302585092994045684;
    uint256 constant LN_100 = 4605170185988091368;
    uint256 constant LN_256 = 5545177444479562475;
    uint256 constant LN_1000 = 6907755278982137052;

    function setUp() public override {
        super.setUp();
        h = deployFixedPointMathHarness();
    }

    // ============================================================
    // wLn Accuracy
    // ============================================================

    function test_wLn_1_exact() public view {
        assertEq(h.wLn(WAD), 0);
    }

    function test_wLn_2_precision() public view {
        uint256 result = h.wLn(2 * WAD);
        _assertRelativeError(result, LN_2, MAX_RELATIVE_ERROR);
    }

    function test_wLn_10_precision() public view {
        uint256 result = h.wLn(10 * WAD);
        _assertRelativeError(result, LN_10, MAX_RELATIVE_ERROR);
    }

    function test_wLn_100_precision() public view {
        uint256 result = h.wLn(100 * WAD);
        _assertRelativeError(result, LN_100, MAX_RELATIVE_ERROR);
    }

    function test_wLn_256_precision() public view {
        uint256 result = h.wLn(256 * WAD);
        _assertRelativeError(result, LN_256, MAX_RELATIVE_ERROR);
    }

    function test_wLn_1000_precision() public view {
        uint256 result = h.wLn(1000 * WAD);
        _assertRelativeError(result, LN_1000, MAX_RELATIVE_ERROR);
    }

    function test_wLn_revertsBelow1() public {
        vm.expectRevert(SE.FP_InvalidInput.selector);
        h.wLn(WAD / 2);
    }

    // ============================================================
    // wExp Accuracy (inverse roundtrip)
    // ============================================================

    function test_expLn_roundtrip_factorDomain() public view {
        uint256[6] memory vals = [uint256(2e18), 5e18, 10e18, 20e18, 50e18, 100e18];
        for (uint256 i = 0; i < 6; i++) {
            uint256 lnX = h.wLn(vals[i]);
            uint256 expLnX = h.wExp(lnX);
            _assertRelativeError(expLnX, vals[i], MAX_RELATIVE_ERROR * 10);
        }
    }

    function test_lnExp_roundtrip_fullDomain() public view {
        uint256[9] memory vals = [uint256(0.1e18), 0.5e18, 1e18, 5e18, 10e18, 20e18, 50e18, 100e18, 130e18];
        for (uint256 i = 0; i < 9; i++) {
            uint256 expX = h.wExp(vals[i]);
            uint256 lnExpX = h.wLn(expX);
            uint256 relErr = vals[i] > 0 ? _relativeError(lnExpX, vals[i]) : _absDiff(lnExpX, vals[i]);
            assertLe(relErr, MAX_RELATIVE_ERROR * 10);
        }
    }

    function test_wExp_maxInput() public view {
        uint256 maxInput = 133_084258667509499440;
        uint256 result = h.wExp(maxInput);
        assertGt(result, 0);
    }

    function test_wExp_revertsAboveMax() public {
        uint256 tooLarge = 133_084258667509499440 + WAD;
        vm.expectRevert(SE.FP_Overflow.selector);
        h.wExp(tooLarge);
    }

    function test_wExp_100WAD() public view {
        uint256 result = h.wExp(100 * WAD);
        assertGt(result, 10 ** 60);
        assertLt(result, 10 ** 62);
    }

    // ============================================================
    // CLMSR Pricing Invariants
    // ============================================================

    function test_fullRangeBuyCostEqualsQuantity() public view {
        uint256 alpha = WAD;
        uint256 quantity = WAD / 10;

        uint256 ratio = h.wExp((quantity * WAD) / alpha);
        uint256 lnRatio = h.wLn(ratio);
        uint256 cost = (alpha * lnRatio) / WAD;

        _assertRelativeError(cost, quantity, MAX_RELATIVE_ERROR * 100);
    }

    function test_roundTripNoArbitrage() public view {
        uint256 zBefore = 10 * WAD;
        uint256 alpha = WAD;
        uint256 quantity = WAD / 10;

        uint256 expFactor = h.wExp((quantity * WAD) / alpha);
        uint256 zAfterBuy = (zBefore * expFactor) / WAD;

        uint256 buyRatio = (zAfterBuy * WAD) / zBefore;
        uint256 buyCost = (alpha * h.wLn(buyRatio)) / WAD;

        uint256 zAfterSell = (zAfterBuy * WAD) / expFactor;
        uint256 sellRatio = (zAfterBuy * WAD) / zAfterSell;
        uint256 sellProceeds = (alpha * h.wLn(sellRatio)) / WAD;

        // Net should be <= 0 (no arbitrage)
        assertLe(sellProceeds, buyCost);
    }

    // ============================================================
    // PnL Calculation Accuracy
    // ============================================================

    function test_pnlMethodsConsistent() public view {
        uint256 alpha = WAD;
        uint256 zStart = 256 * WAD;
        uint256 quantity = WAD / 5;

        uint256 expFactor = h.wExp((quantity * WAD) / alpha);
        uint256 zEnd = (zStart * expFactor) / WAD;

        // Method 1: trade cost = α * ln(Z_end / Z_start)
        uint256 ratio = (zEnd * WAD) / zStart;
        uint256 tradeCost = (alpha * h.wLn(ratio)) / WAD;

        // Method 2: ΔC = α * ln(Z_end) - α * ln(Z_start)
        uint256 lnZEnd = h.wLn(zEnd);
        uint256 lnZStart = h.wLn(zStart);
        uint256 deltaC = (alpha * (lnZEnd - lnZStart)) / WAD;

        _assertRelativeError(deltaC, tradeCost, MAX_RELATIVE_ERROR * 10);
    }

    function test_lnZ_accurateForLargeZ() public view {
        uint256 result = h.wLn(256 * WAD);
        _assertRelativeError(result, LN_256, MAX_RELATIVE_ERROR);
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _relativeError(uint256 actual, uint256 expected) private pure returns (uint256) {
        uint256 diff = _absDiff(actual, expected);
        return (diff * WAD) / expected;
    }

    function _assertRelativeError(uint256 actual, uint256 expected, uint256 maxErr) private pure {
        uint256 relErr = _relativeError(actual, expected);
        assertLe(relErr, maxErr);
    }
}
