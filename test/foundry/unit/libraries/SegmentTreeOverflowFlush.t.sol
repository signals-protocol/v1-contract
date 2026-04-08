// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";

/// @notice SIG-596 regression coverage for flush thresholds and stale leaf pending
contract SegmentTreeOverflowFlushTest is HarnessDeployer {
    LazyMulSegmentTreeHarness h;
    uint32 internal constant NUM_BINS = 80;
    uint256 internal constant DRIFT_BOUND = 1e12;
    uint256 internal constant ROOT_PENDING_AFTER_13_MAX = 1e44;
    uint256 internal constant ROOT_PENDING_AFTER_4_MIN = 1e10;
    uint192 internal constant STALE_LEAF_PENDING = uint192(1e57);
    uint256 internal constant DOUBLE_FACTOR = 2e18;

    function setUp() public override {
        super.setUp();
        h = deployLazyMulSegmentTreeHarness();
        h.initAndSeed(uniformFactors(NUM_BINS));
    }

    function test_leafFastPath_staleHighPending() public {
        uint32 leafIdx = h.resolveLeafNodeIndex(0);
        h.setNodePending(leafIdx, STALE_LEAF_PENDING);

        _applyFullRangeFactorNTimes(MAX_FACTOR, 13);
        assertEq(h.getNodePending(h.getRootIndex()), uint192(ROOT_PENDING_AFTER_13_MAX));

        h.applyRangeFactor(0, 0, DOUBLE_FACTOR);

        assertGt(h.getTotalSum(), 0);
        assertGt(h.getRangeSum(0, 0), 0);
    }

    function test_leafFastPath_stalePendingUnchanged() public {
        uint32 leafIdx = h.resolveLeafNodeIndex(0);
        h.setNodePending(leafIdx, STALE_LEAF_PENDING);

        _applyFullRangeFactorNTimes(MAX_FACTOR, 13);
        h.applyRangeFactor(0, 0, DOUBLE_FACTOR);

        assertEq(h.getNodePending(leafIdx), STALE_LEAF_PENDING);
    }

    function test_noFlushCascadeUnder14MaxFactors() public {
        _applyFullRangeFactorNTimes(MAX_FACTOR, 13);

        assertEq(h.getNodePending(h.getRootIndex()), uint192(ROOT_PENDING_AFTER_13_MAX));
    }

    function test_flushTriggersAt14MaxFactors() public {
        _applyFullRangeFactorNTimes(MAX_FACTOR, 14);

        assertEq(h.getNodePending(h.getRootIndex()), uint192(MAX_FACTOR));
        _assertTreeDriftWithinBound();
    }

    function test_noUnderflowFlushUnder5MinFactors() public {
        _applyFullRangeFactorNTimes(MIN_FACTOR, 4);

        uint192 rootPending = h.getNodePending(h.getRootIndex());
        assertEq(rootPending, uint192(ROOT_PENDING_AFTER_4_MIN));
        assertLt(rootPending, uint192(h.ONE_WAD()));
        assertGt(rootPending, uint192(1e9));
    }

    function test_underflowFlushAt5MinFactors() public {
        _applyFullRangeFactorNTimes(MIN_FACTOR, 5);

        assertEq(h.getNodePending(h.getRootIndex()), uint192(MIN_FACTOR));
        assertGt(h.getTotalSum(), 0);
    }

    function _applyFullRangeFactorNTimes(uint256 factor, uint256 times) internal {
        for (uint256 i = 0; i < times; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, factor);
        }
    }

    function _assertTreeDriftWithinBound() internal view {
        uint256 totalSum = h.getTotalSum();
        uint256 leafSum;

        for (uint32 bin = 0; bin < NUM_BINS; bin++) {
            leafSum += h.getRangeSum(bin, bin);
        }

        uint256 drift = totalSum > leafSum ? totalSum - leafSum : leafSum - totalSum;
        assertLe(drift, DRIFT_BOUND);
    }
}
