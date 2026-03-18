// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";

/// @notice SIG-294 regression: LazyMulSegmentTree overflow flush behavior
contract SegmentTreeOverflowFlushTest is HarnessDeployer {
    LazyMulSegmentTreeHarness h;
    uint32 constant NUM_BINS = 80;

    function setUp() public override {
        super.setUp();
        h = deployLazyMulSegmentTreeHarness();
        h.init(NUM_BINS);
    }

    // ============================================================
    // Reproduction: full-range MAX_FACTOR overflow
    // ============================================================

    function test_survive20FullRangeMaxFactor() public {
        for (uint256 i = 0; i < 20; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
        assertGt(h.getRangeSum(0, NUM_BINS - 1), 0);
    }

    function test_survive25FullRangeMaxFactor() public {
        for (uint256 i = 0; i < 25; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    // ============================================================
    // Alternating up/down factors
    // ============================================================

    function test_alternatingMaxMinFullRange() public {
        for (uint256 i = 0; i < 20; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
            h.applyRangeFactor(0, NUM_BINS - 1, MIN_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    // ============================================================
    // Single-bin extreme
    // ============================================================

    function test_singleBinRepeatedMaxFactor() public {
        for (uint256 i = 0; i < 15; i++) {
            h.applyRangeFactor(0, 0, MAX_FACTOR);
        }
        uint256 singleBinSum = h.getRangeSum(0, 0);
        assertGt(singleBinSum, 0);

        uint256 restSum = h.getRangeSum(1, NUM_BINS - 1);
        assertEq(restSum, 79e18);
    }

    // ============================================================
    // Sum consistency after recursive flush
    // ============================================================

    function test_totalSumEqualsFullRangeSum() public {
        for (uint256 i = 0; i < 15; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }

        uint256 totalSum = h.getTotalSum();
        uint256 fullRangeSum = h.getRangeSum(0, NUM_BINS - 1);

        uint256 drift = totalSum > fullRangeSum ? totalSum - fullRangeSum : fullRangeSum - totalSum;
        uint256 maxDrift = totalSum / 1_000_000_000_000 + 1;
        assertLe(drift, maxDrift);
    }

    // ============================================================
    // Limit probing
    // ============================================================

    function test_singleBinMaxFactorLimit() public {
        // Push single bin to near-limit (15 safe, ~29 is sum overflow)
        uint256 lastSuccess;
        for (uint256 i = 1; i <= 35; i++) {
            try h.applyRangeFactor(0, 0, MAX_FACTOR) {
                lastSuccess = i;
            } catch {
                // Tree should NOT be bricked — other bins still work
                uint256 otherBinSum = h.getRangeSum(1, NUM_BINS - 1);
                assertGt(otherBinSum, 0);
                uint256 bin0Sum = h.getRangeSum(0, 0);
                assertGt(bin0Sum, 0);
                return;
            }
        }
        // If all 35 passed, that's fine too
        assertGt(lastSuccess, 0);
    }

    function test_fullRangeMaxFactorLimit() public {
        uint256 lastSuccess;
        for (uint256 i = 1; i <= 40; i++) {
            try h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR) {
                lastSuccess = i;
            } catch {
                uint256 totalSum = h.getTotalSum();
                assertGt(totalSum, 0);
                return;
            }
        }
        assertGt(lastSuccess, 0);
    }

    function test_sellRecoverAfterNearOverflow() public {
        // Push single bin to near-limit
        for (uint256 i = 0; i < 18; i++) {
            h.applyRangeFactor(0, 0, MAX_FACTOR);
        }

        // Sell (MIN_FACTOR) to reduce pending
        h.applyRangeFactor(0, 0, MIN_FACTOR);

        // Can apply more MAX_FACTOR after sell
        h.applyRangeFactor(0, 0, MAX_FACTOR);

        assertGt(h.getRangeSum(0, 0), 0);
    }

    // ============================================================
    // Factor loss detection: step-by-step
    // ============================================================

    function test_maxFactorMultipliesBy100() public {
        uint256 prevSum = h.getTotalSum();
        assertEq(prevSum, 80e18);

        for (uint256 i = 0; i < 20; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
            uint256 curSum = h.getTotalSum();
            uint256 expected = prevSum * 100;
            uint256 diff = curSum > expected ? curSum - expected : expected - curSum;
            uint256 tolerance = expected / 1_000_000_000_000 + 1;
            assertLe(diff, tolerance);
            prevSum = curSum;
        }
    }

    function test_minFactorDividesBy100() public {
        uint256 prevSum = h.getTotalSum();

        for (uint256 i = 0; i < 10; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MIN_FACTOR);
            uint256 curSum = h.getTotalSum();
            uint256 expected = prevSum / 100;
            uint256 diff = curSum > expected ? curSum - expected : expected - curSum;
            uint256 tolerance = uint256(NUM_BINS) + 1;
            assertLe(diff, tolerance);
            prevSum = curSum;
        }
    }

    function test_propagateLazyMatchesGetRangeSum() public {
        for (uint256 i = 0; i < 10; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }

        uint256 viewSum = h.getRangeSum(0, NUM_BINS - 1);
        uint256 propagatedSum = h.propagateLazy(0, NUM_BINS - 1);

        uint256 diff = viewSum > propagatedSum ? viewSum - propagatedSum : propagatedSum - viewSum;
        assertLe(diff, uint256(NUM_BINS));
    }

    function test_leafSumsEqualTotalSum() public {
        for (uint256 i = 0; i < 12; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }

        h.propagateLazy(0, NUM_BINS - 1);
        uint256 totalSum = h.getTotalSum();

        uint256 leafSum;
        for (uint32 bin = 0; bin < NUM_BINS; bin++) {
            leafSum += h.getRangeSum(bin, bin);
        }

        uint256 drift = totalSum > leafSum ? totalSum - leafSum : leafSum - totalSum;
        uint256 tolerance = totalSum / 1_000_000_000_000 + 1;
        assertLe(drift, tolerance);
    }
}
