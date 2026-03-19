// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/FixedPointMathHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title FixedPointMathFuzz
/// @notice Fuzz tests for FixedPointMathU library — covers arithmetic properties,
///         decimal conversion, exp/ln domain, and CLMSR pricing invariants.
contract FixedPointMathFuzz is HarnessDeployer {
    FixedPointMathHarness h;

    uint256 constant MAX_EXP_INPUT_WAD = 133_084258667509499440;
    uint256 constant SCALE_DIFF = 1e12;
    uint256 constant HALF_SCALE = SCALE_DIFF / 2;

    // Precomputed: wExp(MAX_EXP_INPUT_WAD) — upper bound for lnExp roundtrip
    uint256 MAX_LN_EXP_X;

    // Relative error tolerance for exp/ln roundtrips: 0.001% (matches FixedPointMathPrecision.t.sol)
    uint256 constant ROUNDTRIP_TOLERANCE = WAD / 100_000; // 1e13

    function setUp() public override {
        super.setUp();
        h = deployFixedPointMathHarness();
        MAX_LN_EXP_X = h.wExp(MAX_EXP_INPUT_WAD);
    }

    // ============================================================
    // Helpers (from FixedPointMathPrecision.t.sol)
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

    // ============================================================
    // Group 1: WAD Arithmetic Properties
    // ============================================================

    function testFuzz_wMul_identity(uint256 x) public view {
        assertEq(h.wMul(x, WAD), x);
    }

    function testFuzz_wDiv_identity(uint256 x) public view {
        assertEq(h.wDiv(x, WAD), x);
    }

    function testFuzz_wMul_commutative(uint256 x, uint256 y) public view {
        x = bound(x, 0, type(uint128).max);
        y = bound(y, 0, type(uint128).max);
        assertEq(h.wMul(x, y), h.wMul(y, x));
    }

    function testFuzz_wMulUp_geFloor(uint256 x, uint256 y) public view {
        x = bound(x, 0, type(uint128).max);
        y = bound(y, 0, type(uint128).max);
        assertGe(h.wMulUp(x, y), h.wMul(x, y));
    }

    function testFuzz_wMulNearest_bounded(uint256 x, uint256 y) public view {
        x = bound(x, 0, type(uint128).max);
        y = bound(y, 0, type(uint128).max);
        uint256 floor = h.wMul(x, y);
        uint256 nearest = h.wMulNearest(x, y);
        uint256 ceil = h.wMulUp(x, y);
        assertGe(nearest, floor);
        assertLe(nearest, ceil);
    }

    function testFuzz_wDivUp_geFloor(uint256 x, uint256 y) public view {
        x = bound(x, 0, type(uint256).max / WAD);
        y = bound(y, 1, type(uint256).max);
        assertGe(h.wDivUp(x, y), h.wDiv(x, y));
    }

    function testFuzz_wDivNearest_bounded(uint256 x, uint256 y) public view {
        x = bound(x, 0, type(uint256).max / WAD);
        y = bound(y, 1, type(uint256).max);
        uint256 floor = h.wDiv(x, y);
        uint256 nearest = h.wDivNearest(x, y);
        uint256 ceil = h.wDivUp(x, y);
        assertGe(nearest, floor);
        assertLe(nearest, ceil);
    }

    function testFuzz_wMulDiv_roundtrip(uint256 a, uint256 b) public view {
        a = bound(a, 1e6, 1e36);
        b = bound(b, 1e6, 1e36);
        uint256 product = h.wMul(a, b);
        uint256 recovered = h.wDiv(product, b);
        // Analytical error bound: wMul floor truncation (< 1 unit) amplified by wDiv => WAD/b + 1
        assertLe(_absDiff(recovered, a), WAD / b + 1);
    }

    // ============================================================
    // Group 2: Decimal Conversion Properties
    // ============================================================

    function testFuzz_toWadFromWad_roundtrip(uint256 x6) public view {
        x6 = bound(x6, 0, type(uint256).max / SCALE_DIFF);
        assertEq(h.fromWad(h.toWad(x6)), x6);
    }

    function testFuzz_fromWadToWad_lossy(uint256 xWad) public view {
        uint256 roundtrip = h.toWad(h.fromWad(xWad));
        assertLe(roundtrip, xWad);
        // Lost at most SCALE_DIFF - 1 wei
        assertLe(xWad - roundtrip, SCALE_DIFF - 1);
    }

    function testFuzz_fromWadRoundUp_geFloor(uint256 xWad) public view {
        assertGe(h.fromWadRoundUp(xWad), h.fromWad(xWad));
    }

    function testFuzz_fromWadRoundUp_maxDelta(uint256 xWad) public view {
        assertLe(h.fromWadRoundUp(xWad) - h.fromWad(xWad), 1);
    }

    function testFuzz_fromWadNearestMin1_nonZeroForPositive(uint256 xWad) public view {
        xWad = bound(xWad, 1, type(uint256).max);
        assertGe(h.fromWadNearestMin1(xWad), 1);
    }

    // ============================================================
    // Group 3: Exp/Ln Properties
    // ============================================================

    function testFuzz_expLn_roundtrip(uint256 x) public view {
        x = bound(x, WAD, MAX_EXP_INPUT_WAD);
        uint256 expX = h.wExp(x);
        uint256 lnExpX = h.wLn(expX);
        _assertRelativeError(lnExpX, x, ROUNDTRIP_TOLERANCE);
    }

    function testFuzz_lnExp_roundtrip(uint256 x) public view {
        x = bound(x, WAD, MAX_LN_EXP_X);
        uint256 lnX = h.wLn(x);
        uint256 expLnX = h.wExp(lnX);
        _assertRelativeError(expLnX, x, ROUNDTRIP_TOLERANCE);
    }

    function testFuzz_wExp_monotonic(uint256 a, uint256 b) public view {
        a = bound(a, 0, MAX_EXP_INPUT_WAD);
        b = bound(b, 0, MAX_EXP_INPUT_WAD);
        if (a > b) (a, b) = (b, a);
        assertLe(h.wExp(a), h.wExp(b));
    }

    function testFuzz_wLn_monotonic(uint256 a, uint256 b) public view {
        a = bound(a, WAD, type(uint256).max);
        b = bound(b, WAD, type(uint256).max);
        if (a > b) (a, b) = (b, a);
        assertLe(h.wLn(a), h.wLn(b));
    }

    function testFuzz_wExp_revertsAboveMax(uint256 x) public {
        x = bound(x, MAX_EXP_INPUT_WAD + 1, type(uint256).max);
        vm.expectRevert(SE.FP_Overflow.selector);
        h.wExp(x);
    }

    function testFuzz_wLn_revertsBelowWad(uint256 x) public {
        x = bound(x, 0, WAD - 1);
        vm.expectRevert(SE.FP_InvalidInput.selector);
        h.wLn(x);
    }

    function testFuzz_lnWadUp_monotonic(uint256 a, uint256 b) public view {
        a = bound(a, 2, type(uint256).max / WAD);
        b = bound(b, 2, type(uint256).max / WAD);
        if (a > b) (a, b) = (b, a);
        assertLe(h.lnWadUp(a), h.lnWadUp(b));
    }

    // ============================================================
    // Group 4: CLMSR Pricing Properties
    // ============================================================

    function testFuzz_clmsrCost_noChange_isZero(uint256 alpha, uint256 sum) public view {
        alpha = bound(alpha, 1, 100e18);
        sum = bound(sum, WAD, 1e36);
        assertEq(h.clmsrCost(alpha, sum, sum), 0);
    }

    function testFuzz_clmsrCost_monotonic(
        uint256 alpha,
        uint256 sumBefore,
        uint256 delta1,
        uint256 delta2
    ) public view {
        alpha = bound(alpha, 1, 100e18);
        sumBefore = bound(sumBefore, WAD, 1e36);
        delta1 = bound(delta1, 1, sumBefore);
        delta2 = bound(delta2, 1, sumBefore);
        if (delta1 > delta2) (delta1, delta2) = (delta2, delta1);
        if (delta1 == delta2) return; // skip — equal deltas mean equal costs

        uint256 cost1 = h.clmsrCost(alpha, sumBefore, sumBefore + delta1);
        uint256 cost2 = h.clmsrCost(alpha, sumBefore, sumBefore + delta2);
        assertLe(cost1, cost2);
    }

    function testFuzz_clmsrCost_revertsOnDecrease(uint256 sumBefore, uint256 sumAfter) public {
        sumBefore = bound(sumBefore, WAD + 1, 1e36);
        sumAfter = bound(sumAfter, 1, sumBefore - 1);
        vm.expectRevert(SE.FP_InvalidInput.selector);
        h.clmsrCost(WAD, sumBefore, sumAfter);
    }
}
