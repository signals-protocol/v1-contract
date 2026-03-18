// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/ClmsrMathHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract ClmsrMathTest is HarnessDeployer {
    ClmsrMathHarness h;

    uint256 constant LN_MAX_FACTOR = 4_605170185988091368; // ln(100) * 1e18
    uint256 constant MAX_EXP_INPUT = 135_305999368893231589;

    function setUp() public override {
        super.setUp();
        h = deployClmsrMathHarness();
    }

    // ============================================================
    // maxSafeChunkQuantity
    // ============================================================

    function test_maxSafeChunkQuantity_typicalAlpha() public view {
        uint256 maxSafeQty = h.maxSafeChunkQuantity(WAD);
        assertApproxEqAbs(maxSafeQty, LN_MAX_FACTOR, LN_MAX_FACTOR / 1000);
    }

    function test_maxSafeChunkQuantity_zeroAlpha() public view {
        assertEq(h.maxSafeChunkQuantity(0), 0);
    }

    function test_maxSafeChunkQuantity_scalesLinearly() public view {
        uint256 qty1 = h.maxSafeChunkQuantity(WAD);
        uint256 qty2 = h.maxSafeChunkQuantity(2 * WAD);
        assertApproxEqAbs(qty2, qty1 * 2, qty1 / 100);
    }

    function test_maxSafeChunkQuantity_treeLimitBinding() public view {
        uint256 maxSafeQty = h.maxSafeChunkQuantity(WAD);
        uint256 expLimit = (WAD * MAX_EXP_INPUT) / WAD;
        assertLt(maxSafeQty, expLimit);
    }

    // ============================================================
    // computeSellProceedsFromSumChange
    // ============================================================

    function test_sellProceeds_zeroWhenEqual() public view {
        assertEq(h.computeSellProceedsFromSumChange(WAD, 100e18, 100e18), 0);
        assertEq(h.computeSellProceedsFromSumChange(WAD, 100e18, 100e18 + 1), 0);
    }

    function test_sellProceeds_correctForSell() public view {
        uint256 proceeds = h.computeSellProceedsFromSumChange(WAD, 100e18, 50e18);
        uint256 expectedLn2 = 693147180559945309;
        assertApproxEqAbs(proceeds, expectedLn2, expectedLn2 / 1000);
    }

    function test_sellProceeds_floorDivision() public view {
        uint256 proceeds = h.computeSellProceedsFromSumChange(WAD, 100e18 + 1, 100e18);
        assertLe(proceeds, 1);
    }

    // ============================================================
    // computeBuyCostFromSumChange
    // ============================================================

    function test_buyCost_zeroWhenEqual() public view {
        assertEq(h.computeBuyCostFromSumChange(WAD, 100e18, 100e18), 0);
    }

    function test_buyCost_correctForBuy() public view {
        uint256 cost = h.computeBuyCostFromSumChange(WAD, 100e18, 200e18);
        uint256 expectedLn2 = 693147180559945309;
        assertApproxEqAbs(cost, expectedLn2, expectedLn2 / 1000);
    }

    function test_buyCost_tinyIncrease() public view {
        assertEq(h.computeBuyCostFromSumChange(WAD, 100e18, 100e18 + 1), 0);
    }

    // ============================================================
    // exposedSafeExp
    // ============================================================

    function test_safeExp_expOf1() public view {
        uint256 result = h.exposedSafeExp(WAD, WAD);
        assertApproxEqAbs(result, 2_718281828459045235, uint256(2_718281828459045235) / 1000);
    }

    function test_safeExp_revertsOnZeroAlpha() public {
        vm.expectRevert(SE.InvalidLiquidityParameter.selector);
        h.exposedSafeExp(WAD, 0);
    }

    function test_safeExp_revertsOnOverflow() public {
        vm.expectRevert(SE.FP_Overflow.selector);
        h.exposedSafeExp(MAX_EXP_INPUT + WAD, WAD);
    }

    // ============================================================
    // quoteBuy
    // ============================================================

    function test_quoteBuy_partialRange() public {
        h.seed(_wadArray4());
        uint256 cost = h.quoteBuy(WAD, 0, 1, WAD / 10);
        assertGt(cost, 0);
        assertLt(cost, WAD / 10);
    }

    function test_quoteBuy_fullRangeCostApproxQuantity() public {
        h.seed(_wadArray4());
        uint256 q = WAD / 10;
        uint256 cost = h.quoteBuy(WAD, 0, 3, q);
        assertApproxEqAbs(cost, q, q / 100);
    }

    function test_quoteBuy_zeroQuantity() public {
        h.seed(_wadArray4());
        assertEq(h.quoteBuy(WAD, 0, 1, 0), 0);
    }

    // ============================================================
    // quoteSell
    // ============================================================

    function test_quoteSell_positive() public {
        uint256[] memory f = new uint256[](4);
        f[0] = 2 * WAD;
        f[1] = 2 * WAD;
        f[2] = WAD;
        f[3] = WAD;
        h.seed(f);
        uint256 proceeds = h.quoteSell(WAD, 0, 1, WAD / 10);
        assertGt(proceeds, 0);
    }

    function test_quoteSell_zeroQuantity() public {
        h.seed(_wadArray4());
        assertEq(h.quoteSell(WAD, 0, 1, 0), 0);
    }

    // ============================================================
    // quantityFromCost
    // ============================================================

    function test_quantityFromCost_positive() public {
        h.seed(_wadArray4());
        uint256 q = h.quantityFromCost(WAD, 0, 1, WAD / 10);
        assertGt(q, 0);
    }

    function test_quantityFromCost_zeroCost() public {
        h.seed(_wadArray4());
        assertEq(h.quantityFromCost(WAD, 0, 1, 0), 0);
    }

    // ============================================================
    // Error paths
    // ============================================================

    function test_quoteBuy_revertsTreeNotInitialized() public {
        vm.expectRevert(SE.TreeNotInitialized.selector);
        h.quoteBuy(WAD, 0, 1, WAD);
    }

    function test_quoteSell_revertsTreeNotInitialized() public {
        vm.expectRevert(SE.TreeNotInitialized.selector);
        h.quoteSell(WAD, 0, 1, WAD);
    }

    function test_quantityFromCost_revertsTreeNotInitialized() public {
        vm.expectRevert(SE.TreeNotInitialized.selector);
        h.quantityFromCost(WAD, 0, 1, WAD);
    }

    // ============================================================
    // Edge Cases: Large trades and chunking
    // ============================================================

    function test_tradeWithinSafeLimit() public {
        h.seed(_wadArray4());
        uint256 safeQty = h.maxSafeChunkQuantity(WAD);
        uint256 cost = h.quoteBuy(WAD, 0, 1, safeQty);
        assertGt(cost, 0);
    }

    function test_tradeAboveSafeLimitTriggersChunking() public {
        h.seed(_wadArray4());
        uint256 safeQty = h.maxSafeChunkQuantity(WAD);
        uint256 cost = h.quoteBuy(WAD, 0, 1, safeQty + WAD);
        assertGt(cost, 0);
    }

    function test_verySmallAlpha() public {
        h.seed(_wadArray4());
        uint256 smallAlpha = WAD / 1000;
        uint256 safeQty = h.maxSafeChunkQuantity(smallAlpha);
        assertApproxEqAbs(safeQty, LN_MAX_FACTOR / 1000, LN_MAX_FACTOR / 10000);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _wadArray4() private pure returns (uint256[] memory f) {
        f = new uint256[](4);
        f[0] = 1e18;
        f[1] = 1e18;
        f[2] = 1e18;
        f[3] = 1e18;
    }
}
