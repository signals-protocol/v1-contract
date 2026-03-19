// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/ExposureDiffLibHarness.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title ExposureDiffLibFuzzTest
/// @notice Foundry-native fuzz tests for ExposureDiffLib invariants and revert conditions.
/// @dev Each fuzz run deploys a fresh harness via setUp(), so storage starts clean.
contract ExposureDiffLibFuzzTest is HarnessDeployer {
    ExposureDiffLibHarness harness;
    uint32 constant NUM_BINS = 100;

    function setUp() public override {
        super.setUp();
        harness = deployExposureDiffLibHarness();
    }

    // ============================================================
    // Positive fuzz tests
    // ============================================================

    /// @notice INV-DIFF2: rangeAdd creates correct diff pattern
    function testFuzz_rangeAddDiffPattern(uint256 rawLo, uint256 rawHi, uint256 rawDelta) public {
        uint32 lo = uint32(bound(rawLo, 0, uint256(NUM_BINS - 1)));
        uint32 hi = uint32(bound(rawHi, uint256(lo), uint256(NUM_BINS - 1)));
        int256 delta = int256(bound(rawDelta, 1, 1000e18));

        harness.rangeAdd(lo, hi, delta, NUM_BINS);

        assertEq(harness.getDiff(lo), delta, "DIFF2: diff[lo] != delta");

        if (hi + 1 < NUM_BINS) {
            assertEq(harness.getDiff(hi + 1), -delta, "DIFF2: diff[hi+1] != -delta");
        }
    }

    /// @notice INV-DIFF3: pointQuery non-negative after single positive rangeAdd
    function testFuzz_pointQueryNonNegative(uint256 rawLo, uint256 rawHi, uint256 rawDelta, uint256 rawBin) public {
        uint32 lo = uint32(bound(rawLo, 0, uint256(NUM_BINS - 1)));
        uint32 hi = uint32(bound(rawHi, uint256(lo), uint256(NUM_BINS - 1)));
        int256 delta = int256(bound(rawDelta, 1, 1000e18));
        uint32 bin = uint32(bound(rawBin, 0, uint256(NUM_BINS - 1)));

        harness.rangeAdd(lo, hi, delta, NUM_BINS);

        uint256 exposure = harness.pointQuery(bin);
        assertGe(exposure, 0, "DIFF3: negative exposure after positive rangeAdd");
    }

    /// @notice INV-DIFF3: pointQuery non-negative after multiple positive rangeAdds
    function testFuzz_multipleAddsNonNegative(uint64 seed) public {
        Prng memory prng = createPrng(seed);

        uint256 numAdds = nextInRange(prng, 5, 11);
        for (uint256 i = 0; i < numAdds; i++) {
            uint32 lo = uint32(nextInRange(prng, 0, uint256(NUM_BINS)));
            uint32 hi = uint32(nextInRange(prng, uint256(lo), uint256(NUM_BINS)));
            // Clamp hi to valid range
            if (hi >= NUM_BINS) hi = NUM_BINS - 1;
            int256 delta = int256(nextInRange(prng, 1, 1001)) * 1e18;

            harness.rangeAdd(lo, hi, delta, NUM_BINS);
        }

        for (uint32 i = 0; i < NUM_BINS; i++) {
            uint256 exposure = harness.pointQuery(i);
            assertGe(exposure, 0, "DIFF3: negative exposure after multiple positive adds");
        }
    }

    /// @notice Inverse property: +delta then -delta on same range yields zero exposure
    function testFuzz_addRemoveNetZero(uint256 rawLo, uint256 rawHi, uint256 rawDelta) public {
        uint32 lo = uint32(bound(rawLo, 0, uint256(NUM_BINS - 1)));
        uint32 hi = uint32(bound(rawHi, uint256(lo), uint256(NUM_BINS - 1)));
        int256 delta = int256(bound(rawDelta, 1, 1000e18));

        harness.rangeAdd(lo, hi, delta, NUM_BINS);
        harness.rangeAdd(lo, hi, -delta, NUM_BINS);

        for (uint32 i = 0; i < NUM_BINS; i++) {
            assertEq(harness.pointQuery(i), 0, "Net zero: non-zero exposure after add+remove");
        }
    }

    // ============================================================
    // Negative fuzz tests (revert verification)
    // ============================================================

    /// @notice ExposureDiffInvalidRange when lo > hi
    function testFuzz_revert_invalidRange(uint256 rawLo, uint256 rawHi) public {
        uint32 lo = uint32(bound(rawLo, 1, uint256(NUM_BINS - 1)));
        uint32 hi = uint32(bound(rawHi, 0, uint256(lo - 1)));

        vm.expectRevert(
            abi.encodeWithSelector(SE.ExposureDiffInvalidRange.selector, int256(uint256(lo)), int256(uint256(hi)))
        );
        harness.rangeAdd(lo, hi, 100e18, NUM_BINS);
    }

    /// @notice ExposureDiffBinOutOfBounds when hi >= NUM_BINS
    function testFuzz_revert_binOutOfBounds(uint256 rawLo, uint256 rawHi) public {
        uint32 lo = uint32(bound(rawLo, 0, uint256(NUM_BINS - 1)));
        uint32 hi = uint32(bound(rawHi, uint256(NUM_BINS), uint256(NUM_BINS) + 1000));

        vm.expectRevert(abi.encodeWithSelector(SE.ExposureDiffBinOutOfBounds.selector, int256(uint256(hi)), NUM_BINS));
        harness.rangeAdd(lo, hi, 100e18, NUM_BINS);
    }

    /// @notice ExposureDiffNegativeExposure when subtracting from empty state
    function testFuzz_revert_negativeExposure(uint256 rawLo, uint256 rawHi, uint256 rawDelta, uint256 rawBin) public {
        uint32 lo = uint32(bound(rawLo, 0, uint256(NUM_BINS - 1)));
        uint32 hi = uint32(bound(rawHi, uint256(lo), uint256(NUM_BINS - 1)));
        int256 delta = int256(bound(rawDelta, 1, 1000e18));
        uint32 bin = uint32(bound(rawBin, uint256(lo), uint256(hi)));

        // Subtract from empty state → negative prefix sum
        harness.rangeAdd(lo, hi, -delta, NUM_BINS);

        int256 expectedSum = -delta;
        vm.expectRevert(
            abi.encodeWithSelector(SE.ExposureDiffNegativeExposure.selector, int256(uint256(bin)), expectedSum)
        );
        harness.pointQuery(bin);
    }
}
