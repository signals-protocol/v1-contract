// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/ExposureDiffLibHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

contract ExposureDiffLibTest is HarnessDeployer {
    ExposureDiffLibHarness harness;
    uint32 constant NUM_BINS = 10;

    function setUp() public override {
        super.setUp();
        harness = deployExposureDiffLibHarness();
    }

    // ============================================================
    // rangeAdd
    // ============================================================

    function test_rangeAdd_singleBin() public {
        harness.rangeAdd(5, 5, 100, NUM_BINS);

        assertEq(harness.getDiff(5), 100);
        assertEq(harness.getDiff(6), -100);
        assertEq(harness.pointQuery(5), 100);
        assertEq(harness.pointQuery(6), 0);
    }

    function test_rangeAdd_range() public {
        harness.rangeAdd(2, 5, 50, NUM_BINS);

        assertEq(harness.pointQuery(0), 0);
        assertEq(harness.pointQuery(1), 0);
        assertEq(harness.pointQuery(2), 50);
        assertEq(harness.pointQuery(3), 50);
        assertEq(harness.pointQuery(4), 50);
        assertEq(harness.pointQuery(5), 50);
        assertEq(harness.pointQuery(6), 0);
    }

    function test_rangeAdd_multipleOverlapping() public {
        harness.rangeAdd(0, 4, 100, NUM_BINS);
        harness.rangeAdd(3, 7, 50, NUM_BINS);

        assertEq(harness.pointQuery(0), 100);
        assertEq(harness.pointQuery(2), 100);
        assertEq(harness.pointQuery(3), 150);
        assertEq(harness.pointQuery(4), 150);
        assertEq(harness.pointQuery(5), 50);
        assertEq(harness.pointQuery(7), 50);
        assertEq(harness.pointQuery(8), 0);
    }

    function test_rangeAdd_lastBin() public {
        harness.rangeAdd(8, 9, 100, NUM_BINS);

        assertEq(harness.pointQuery(8), 100);
        assertEq(harness.pointQuery(9), 100);
    }

    function test_rangeAdd_revertsWhenLoGtHi() public {
        vm.expectRevert(abi.encodeWithSelector(SE.ExposureDiffInvalidRange.selector, int256(5), int256(3)));
        harness.rangeAdd(5, 3, 100, NUM_BINS);
    }

    function test_rangeAdd_revertsWhenHiGeNumBins() public {
        vm.expectRevert(abi.encodeWithSelector(SE.ExposureDiffBinOutOfBounds.selector, int256(10), uint32(10)));
        harness.rangeAdd(0, uint32(NUM_BINS), 100, NUM_BINS);
    }

    function test_rangeAdd_zeroDeltaIsNoop() public {
        harness.rangeAdd(2, 5, 0, NUM_BINS);

        assertEq(harness.pointQuery(2), 0);
        assertEq(harness.pointQuery(5), 0);
    }

    function test_rangeAdd_fullRange() public {
        harness.rangeAdd(0, NUM_BINS - 1, 100, NUM_BINS);

        for (uint32 i = 0; i < NUM_BINS; i++) {
            assertEq(harness.pointQuery(i), 100);
        }
    }

    function test_rangeAdd_lastBinDiffPattern() public {
        harness.rangeAdd(8, 9, 100, NUM_BINS);

        assertEq(harness.getDiff(8), 100);
        assertEq(harness.pointQuery(8), 100);
        assertEq(harness.pointQuery(9), 100);
    }

    // ============================================================
    // Subtraction (negative delta)
    // ============================================================

    function test_rangeAdd_negativeDelta() public {
        harness.rangeAdd(2, 6, 100, NUM_BINS);
        harness.rangeAdd(4, 5, -30, NUM_BINS);

        assertEq(harness.pointQuery(2), 100);
        assertEq(harness.pointQuery(3), 100);
        assertEq(harness.pointQuery(4), 70);
        assertEq(harness.pointQuery(5), 70);
        assertEq(harness.pointQuery(6), 100);
    }

    // ============================================================
    // rawPrefixSum
    // ============================================================

    function test_rawPrefixSum_signedSum() public {
        harness.rangeAdd(0, 2, 50, NUM_BINS);
        harness.rangeAdd(1, 3, -100, NUM_BINS);

        assertEq(harness.rawPrefixSum(0), 50);
        assertEq(harness.rawPrefixSum(1), -50);
        assertEq(harness.rawPrefixSum(2), -50);
        assertEq(harness.rawPrefixSum(3), -100);
        assertEq(harness.rawPrefixSum(4), 0);
    }

    // ============================================================
    // Negative exposure revert
    // ============================================================

    function test_pointQuery_revertsOnNegativeExposure() public {
        harness.rangeAdd(0, 5, -100, NUM_BINS);

        vm.expectRevert(abi.encodeWithSelector(SE.ExposureDiffNegativeExposure.selector, int256(3), int256(-100)));
        harness.pointQuery(3);
    }
}
