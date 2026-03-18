// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/FixedPointMathHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract FixedPointMathTest is HarnessDeployer {
    FixedPointMathHarness h;

    function setUp() public override {
        super.setUp();
        h = deployFixedPointMathHarness();
    }

    // ============================================================
    // wMul
    // ============================================================

    function test_wMul_2x3eq6() public view {
        assertEq(h.wMul(TWO_WAD, 3e18), 6e18);
    }

    function test_wMul_halfxhalf() public view {
        assertEq(h.wMul(HALF_WAD, HALF_WAD), 0.25e18);
    }

    function test_wMul_byZero() public view {
        assertEq(h.wMul(TWO_WAD, 0), 0);
    }

    function test_wMul_byWad() public view {
        assertEq(h.wMul(5e18, WAD), 5e18);
    }

    // ============================================================
    // wDiv
    // ============================================================

    function test_wDiv_6div2() public view {
        assertEq(h.wDiv(6e18, TWO_WAD), 3e18);
    }

    function test_wDiv_1div2() public view {
        assertEq(h.wDiv(WAD, TWO_WAD), HALF_WAD);
    }

    function test_wDiv_revertsOnZero() public {
        vm.expectRevert(SE.FP_DivisionByZero.selector);
        h.wDiv(WAD, 0);
    }

    function test_wDiv_byWad() public view {
        assertEq(h.wDiv(5e18, WAD), 5e18);
    }

    // ============================================================
    // wMulNearest
    // ============================================================

    function test_wMulNearest_exact() public view {
        assertEq(h.wMulNearest(WAD, WAD), WAD);
    }

    function test_wMulNearest_roundsDown() public view {
        uint256 result = h.wMulNearest(WAD, WAD + 1);
        assertApproxEqAbs(result, WAD, 1);
    }

    function test_wMulNearest_byZero() public view {
        assertEq(h.wMulNearest(TWO_WAD, 0), 0);
    }

    // ============================================================
    // wMulUp
    // ============================================================

    function test_wMulUp_roundsUp() public view {
        uint256 up = h.wMulUp(WAD + 1, WAD + 1);
        uint256 down = h.wMul(WAD + 1, WAD + 1);
        assertGe(up, down);
    }

    function test_wMulUp_exactNoRemainder() public view {
        assertEq(h.wMulUp(TWO_WAD, TWO_WAD), 4e18);
    }

    function test_wMulUp_byZero() public view {
        assertEq(h.wMulUp(TWO_WAD, 0), 0);
    }

    // ============================================================
    // wDivUp
    // ============================================================

    function test_wDivUp_roundsUp() public view {
        uint256 up = h.wDivUp(WAD, 3e18);
        uint256 down = h.wDiv(WAD, 3e18);
        assertGe(up, down);
    }

    function test_wDivUp_exactNoRemainder() public view {
        assertEq(h.wDivUp(6e18, TWO_WAD), 3e18);
    }

    function test_wDivUp_byWad() public view {
        assertEq(h.wDivUp(5e18, WAD), 5e18);
    }

    function test_wDivUp_revertsOnZero() public {
        vm.expectRevert(SE.FP_DivisionByZero.selector);
        h.wDivUp(WAD, 0);
    }

    // ============================================================
    // wDivNearest
    // ============================================================

    function test_wDivNearest_roundsToNearest() public view {
        uint256 result = h.wDivNearest(5e18, 3e18);
        assertApproxEqAbs(result, 1_666666666666666666, 1);
    }

    function test_wDivNearest_exactDivision() public view {
        assertEq(h.wDivNearest(6e18, TWO_WAD), 3e18);
    }

    function test_wDivNearest_revertsOnZero() public {
        vm.expectRevert(SE.FP_DivisionByZero.selector);
        h.wDivNearest(WAD, 0);
    }

    // ============================================================
    // wExp
    // ============================================================

    function test_wExp_zero() public view {
        assertEq(h.wExp(0), WAD);
    }

    function test_wExp_one() public view {
        uint256 result = h.wExp(WAD);
        assertApproxEqAbs(result, 2_718281828459045235, LOOSE_TOLERANCE);
    }

    function test_wExp_two() public view {
        uint256 result = h.wExp(TWO_WAD);
        assertApproxEqAbs(result, 7_389056098930650000, LOOSE_TOLERANCE);
    }

    function test_wExp_revertsOnOverflow() public {
        uint256 MAX_EXP_INPUT_WAD = 133_084258667509499440;
        vm.expectRevert(SE.FP_Overflow.selector);
        h.wExp(MAX_EXP_INPUT_WAD + 1);
    }

    function test_wExp_succeedsAtMaxBoundary() public view {
        uint256 MAX_EXP_INPUT_WAD = 133_084258667509499440;
        uint256 result = h.wExp(MAX_EXP_INPUT_WAD);
        assertGt(result, 0);
    }

    // ============================================================
    // wLn
    // ============================================================

    function test_wLn_one() public view {
        assertEq(h.wLn(WAD), 0);
    }

    function test_wLn_e() public view {
        uint256 result = h.wLn(2_718281828459045235);
        assertApproxEqAbs(result, WAD, LOOSE_TOLERANCE);
    }

    function test_wLn_two() public view {
        uint256 result = h.wLn(TWO_WAD);
        assertApproxEqAbs(result, 693147180559945309, LOOSE_TOLERANCE);
    }

    function test_wLn_revertsOnZero() public {
        vm.expectRevert(SE.FP_InvalidInput.selector);
        h.wLn(0);
    }

    // ============================================================
    // lnWadUp
    // ============================================================

    function test_lnWadUp_2() public view {
        uint256 result = h.lnWadUp(2);
        assertGt(result, 0);
    }

    function test_lnWadUp_1() public view {
        assertEq(h.lnWadUp(1), 0);
    }

    function test_lnWadUp_0() public view {
        assertEq(h.lnWadUp(0), 0);
    }

    // ============================================================
    // toWad / fromWad conversions
    // ============================================================

    function test_toWad_1USDC() public view {
        assertEq(h.toWad(1_000_000), WAD);
    }

    function test_toWad_zero() public view {
        assertEq(h.toWad(0), 0);
    }

    function test_toWad_revertsOnOverflow() public {
        uint256 maxSafe = type(uint256).max / 1e12;
        vm.expectRevert(SE.FP_Overflow.selector);
        h.toWad(maxSafe + 1);
    }

    function test_fromWad_truncates() public view {
        assertEq(h.fromWad(WAD), 1_000_000);
        assertEq(h.fromWad(WAD + HALF_WAD), 1_500_000);
    }

    function test_fromWadRoundUp_roundsUp() public view {
        assertEq(h.fromWadRoundUp(WAD + 1), 1_000_001);
    }

    function test_fromWadRoundUp_exactNotRounded() public view {
        assertEq(h.fromWadRoundUp(WAD), 1_000_000);
    }

    function test_fromWadRoundUp_zero() public view {
        assertEq(h.fromWadRoundUp(0), 0);
    }

    function test_fromWadNearest_roundsDown() public view {
        assertEq(h.fromWadNearest(WAD + 400_000_000_000), 1_000_000);
    }

    function test_fromWadNearest_roundsUp() public view {
        assertEq(h.fromWadNearest(WAD + 600_000_000_000), 1_000_001);
    }

    function test_fromWadNearestMin1_nonZero() public view {
        assertEq(h.fromWadNearestMin1(1), 1);
    }

    function test_fromWadNearestMin1_zero() public view {
        assertEq(h.fromWadNearestMin1(0), 0);
    }

    // ============================================================
    // clmsrCost
    // ============================================================

    function test_clmsrCost_correct() public view {
        uint256 sumBefore = 4e18;
        uint256 e_ = 2_718281828459045235;
        uint256 sumAfter = h.wMul(sumBefore, e_);
        uint256 cost = h.clmsrCost(WAD, sumBefore, sumAfter);
        assertApproxEqAbs(cost, WAD, LOOSE_TOLERANCE);
    }

    function test_clmsrCost_noChange() public view {
        assertEq(h.clmsrCost(WAD, 10e18, 10e18), 0);
    }

    // ============================================================
    // Property: mul/div roundtrip
    // ============================================================

    function test_property_mulDivRoundtrip() public view {
        Prng memory prng = createPrng(12345);

        for (uint256 i = 0; i < 10; i++) {
            uint256 a = nextInRange(prng, WAD / 10, WAD * 100);
            uint256 b = nextInRange(prng, WAD / 10, WAD * 100);
            uint256 product = h.wMul(a, b);
            uint256 back = h.wDiv(product, b);
            assertApproxEqAbs(back, a, 2);
        }
    }

    // ============================================================
    // Property: exp/ln roundtrip
    // ============================================================

    function test_property_lnExpRoundtrip() public view {
        uint256 TAYLOR_TOLERANCE = 0.000001e18;
        uint256[3] memory vals = [uint256(0.1e18), 0.5e18, 1e18];

        for (uint256 i = 0; i < 3; i++) {
            uint256 expX = h.wExp(vals[i]);
            uint256 lnExpX = h.wLn(expX);
            assertApproxEqAbs(lnExpX, vals[i], TAYLOR_TOLERANCE);
        }
    }

    function test_property_expLnRoundtrip() public view {
        uint256[3] memory vals = [uint256(1.1e18), 1.5e18, 2e18];

        for (uint256 i = 0; i < 3; i++) {
            uint256 lnX = h.wLn(vals[i]);
            uint256 expLnX = h.wExp(lnX);
            uint256 tolerance = vals[i] / 10000;
            assertApproxEqAbs(expLnX, vals[i], tolerance);
        }
    }

    // ============================================================
    // Property: large values
    // ============================================================

    function test_property_largeMul() public view {
        assertEq(h.wMul(1_000_000e18, WAD), 1_000_000e18);
    }

    function test_property_largeDiv() public view {
        assertEq(h.wDiv(1_000_000e18, WAD), 1_000_000e18);
    }
}
