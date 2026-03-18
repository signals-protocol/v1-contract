// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";

contract LazyMulSegmentTreeTest is HarnessDeployer {
    LazyMulSegmentTreeHarness h;

    function setUp() public override {
        super.setUp();
        h = deployLazyMulSegmentTreeHarness();
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Equivalent to TS prng.nextInt(maxExclusive) — returns uint32 in [0, max).
    function nextInt(Prng memory prng, uint32 max) internal pure returns (uint32) {
        return uint32(nextRand(prng) % uint64(max));
    }

    /// @dev WAD-based wMulNearest for naive model: (a * b + WAD/2) / WAD.
    function wMulNearest(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + WAD / 2) / WAD;
    }

    // ============================================================
    // init
    // ============================================================

    function test_init_correctSize() public {
        h.init(100);
        assertEq(h.getTreeSize(), 100);
    }

    function test_init_revertsOnZeroSize() public {
        vm.expectRevert();
        h.init(0);
    }

    function test_init_harnessAllowsReInit() public {
        h.init(10);
        h.init(20);
        assertEq(h.getTreeSize(), 20);
    }

    function test_init_revertsOnSizeTooLarge() public {
        uint32 maxU32 = type(uint32).max;
        vm.expectRevert();
        h.init(maxU32);
    }

    // ============================================================
    // initAndSeed
    // ============================================================

    function test_initAndSeed_seedsWithGivenFactors() public {
        uint256[] memory factors = new uint256[](4);
        factors[0] = WAD;
        factors[1] = TWO_WAD;
        factors[2] = 3e18;
        factors[3] = 4e18;
        h.initAndSeed(factors);

        assertEq(h.getTreeSize(), 4);
        // Total sum should be 1 + 2 + 3 + 4 = 10 WAD
        assertEq(h.getTotalSum(), 10e18);
    }

    function test_initAndSeed_revertsOnEmptyFactors() public {
        uint256[] memory factors = new uint256[](0);
        vm.expectRevert();
        h.initAndSeed(factors);
    }

    function test_seedWithFactors_revertsOnLengthMismatch() public {
        h.init(10);
        // 10 bins but only 5 factors
        uint256[] memory factors = uniformFactors(5);
        vm.expectRevert();
        h.seedWithFactors(factors);
    }

    // ============================================================
    // getRangeSum
    // ============================================================

    function test_getRangeSum_singleElement() public {
        _seedUniform4();
        assertEq(h.getRangeSum(0, 0), WAD);
    }

    function test_getRangeSum_fullRange() public {
        _seedUniform4();
        assertEq(h.getRangeSum(0, 3), 4e18);
    }

    function test_getRangeSum_partialRange() public {
        _seedUniform4();
        assertEq(h.getRangeSum(1, 2), TWO_WAD);
    }

    function test_getRangeSum_revertsOnInvalidRange() public {
        _seedUniform4();
        vm.expectRevert();
        h.getRangeSum(3, 1);
    }

    function test_getRangeSum_revertsOnOutOfBounds() public {
        _seedUniform4();
        vm.expectRevert();
        h.getRangeSum(0, 10);
    }

    // ============================================================
    // applyRangeFactor
    // ============================================================

    function test_applyRangeFactor_multipliesSingleElement() public {
        _seedUniform4();
        h.applyRangeFactor(0, 0, TWO_WAD);

        assertEq(h.getNodeValue(0), TWO_WAD);
        // Other elements unchanged
        assertEq(h.getNodeValue(1), WAD);
    }

    function test_applyRangeFactor_multipliesRange() public {
        _seedUniform4();
        h.applyRangeFactor(0, 3, TWO_WAD);

        // All elements doubled: 4 * 2 = 8 WAD total
        assertEq(h.getTotalSum(), 8e18);
    }

    function test_applyRangeFactor_multipleFactors() public {
        _seedUniform4();

        // First: multiply [0,1] by 2
        h.applyRangeFactor(0, 1, TWO_WAD);
        // Second: multiply [1,2] by 3
        h.applyRangeFactor(1, 2, 3e18);

        // Element 0: 1 * 2 = 2
        // Element 1: 1 * 2 * 3 = 6
        // Element 2: 1 * 3 = 3
        // Element 3: 1
        assertEq(h.getTotalSum(), 12e18);
    }

    function test_applyRangeFactor_revertsOnFactorBelowMin() public {
        _seedUniform4();
        uint256 tooSmall = 0.001e18; // < 0.01
        vm.expectRevert();
        h.applyRangeFactor(0, 0, tooSmall);
    }

    function test_applyRangeFactor_revertsOnFactorAboveMax() public {
        _seedUniform4();
        uint256 tooLarge = 200e18; // > 100
        vm.expectRevert();
        h.applyRangeFactor(0, 0, tooLarge);
    }

    function test_applyRangeFactor_revertsOnInvalidRange() public {
        _seedUniform4();
        vm.expectRevert();
        h.applyRangeFactor(3, 1, TWO_WAD);
    }

    // ============================================================
    // Lazy propagation
    // ============================================================

    function test_lazyPropagation_deferredCorrectly() public {
        h.init(100);
        h.seedWithFactors(uniformFactors(100));

        // Multiple overlapping range operations
        h.applyRangeFactor(10, 30, TWO_WAD);
        h.applyRangeFactor(20, 40, 3e18);
        h.applyRangeFactor(5, 25, HALF_WAD);

        // Index 15: 1 * 2 * 0.5 = 1
        assertEq(h.getNodeValue(15), WAD);

        // Index 25: 1 * 2 * 3 * 0.5 = 3
        assertApproxEqAbs(h.getNodeValue(25), 3e18, 10);

        // Index 35: 1 * 3 = 3
        assertEq(h.getNodeValue(35), 3e18);

        // Index 50: unchanged = 1
        assertEq(h.getNodeValue(50), WAD);
    }

    // ============================================================
    // Edge cases
    // ============================================================

    function test_edge_treeOfSize1() public {
        uint256[] memory factors = new uint256[](1);
        factors[0] = WAD;
        h.initAndSeed(factors);

        assertEq(h.getTotalSum(), WAD);

        h.applyRangeFactor(0, 0, TWO_WAD);
        assertEq(h.getTotalSum(), TWO_WAD);
    }

    function test_edge_minimumValidFactor() public {
        _seedUniform4();
        h.applyRangeFactor(0, 0, MIN_FACTOR);

        // 1 * 0.01 = 0.01
        assertApproxEqAbs(h.getNodeValue(0), MIN_FACTOR, 10);
    }

    function test_edge_maximumValidFactor() public {
        _seedUniform4();
        h.applyRangeFactor(0, 0, MAX_FACTOR);

        // 1 * 100 = 100
        assertEq(h.getNodeValue(0), MAX_FACTOR);
    }

    function test_edge_factorOfExactlyOne() public {
        _seedUniform4();
        uint256 before = h.getTotalSum();
        h.applyRangeFactor(0, 3, WAD);
        uint256 after_ = h.getTotalSum();
        assertEq(after_, before);
    }

    // ============================================================
    // Property: sum consistency
    // ============================================================

    function test_sumConsistency_totalEqSumOfNodes() public {
        h.init(100);
        Prng memory prng = createPrng(42);
        uint256[] memory factors = randomFactors(prng, 100, MIN_FACTOR, MAX_FACTOR);
        h.seedWithFactors(factors);

        // Calculate expected total from individual nodes
        uint256 expected;
        for (uint32 i = 0; i < 100; i++) {
            expected += h.getNodeValue(i);
        }

        uint256 total = h.getTotalSum();
        assertApproxEqAbs(total, expected, 100);
    }

    function test_sumConsistency_preservedAfterOperations() public {
        h.init(100);
        h.seedWithFactors(uniformFactors(100));

        Prng memory prng = createPrng(123);

        // Apply 10 random range operations
        for (uint256 i = 0; i < 10; i++) {
            uint32 lo = nextInt(prng, 100);
            uint32 hi = lo + nextInt(prng, 100 - lo);
            uint256 factor = nextInRange(prng, MIN_FACTOR, MAX_FACTOR);
            h.applyRangeFactor(lo, hi, factor);
        }

        // Verify sum consistency
        uint256 computed;
        for (uint32 i = 0; i < 100; i++) {
            computed += h.getNodeValue(i);
        }

        uint256 total = h.getTotalSum();
        // Allow larger tolerance due to accumulated WAD rounding
        assertApproxEqAbs(total, computed, 10000);
    }

    // ============================================================
    // Property: monotonicity
    // ============================================================

    function test_monotonicity_factorGt1IncreasesSum() public {
        _seedUniform4();

        uint256 before = h.getRangeSum(0, 1);
        h.applyRangeFactor(0, 1, TWO_WAD);
        uint256 after_ = h.getRangeSum(0, 1);

        assertGt(after_, before);
    }

    function test_monotonicity_factorLt1DecreasesSum() public {
        _seedUniform4();

        uint256 before = h.getRangeSum(0, 1);
        h.applyRangeFactor(0, 1, HALF_WAD);
        uint256 after_ = h.getRangeSum(0, 1);

        assertLt(after_, before);
    }

    // ============================================================
    // Non-uniform distribution
    // ============================================================

    function test_nonUniform_initialFactors() public {
        uint256[] memory factors = new uint256[](4);
        factors[0] = 1e18;
        factors[1] = 2e18;
        factors[2] = 4e18;
        factors[3] = 8e18;
        h.initAndSeed(factors);

        // Total: 1 + 2 + 4 + 8 = 15
        assertEq(h.getTotalSum(), 15e18);

        // Apply factor to middle range
        h.applyRangeFactor(1, 2, TWO_WAD);

        // New total: 1 + 4 + 8 + 8 = 21
        assertEq(h.getTotalSum(), 21e18);
    }

    // ============================================================
    // Edge cases: cancellation (f then 1/f)
    // ============================================================

    function test_cancellation_fThenInversePreservesSubrange() public {
        // 8 bins for better coverage of internal nodes
        h.initAndSeed(uniformFactors(8));

        uint256 totalBefore = h.getTotalSum();
        uint256 subrangeBefore = h.getRangeSum(0, 3);

        // Apply f=2 to partial range [0,3]
        h.applyRangeFactor(0, 3, TWO_WAD);

        // Apply inverse f=0.5 to same range -> combinedPending should become ONE_WAD
        h.applyRangeFactor(0, 3, HALF_WAD);

        // Total and subrange should return to original (within rounding tolerance)
        assertApproxEqAbs(h.getTotalSum(), totalBefore, 10);
        assertApproxEqAbs(h.getRangeSum(0, 3), subrangeBefore, 10);
    }

    function test_cancellation_nestedRangesWithInverseFactors() public {
        h.initAndSeed(uniformFactors(16));

        // Apply f=4 to [0,7]
        h.applyRangeFactor(0, 7, 4e18);

        // Apply f=0.25 to [0,7] -> cancellation
        h.applyRangeFactor(0, 7, 0.25e18);

        // Subrange query should match original: 4 bins * 1 WAD = 4 WAD
        assertApproxEqAbs(h.getRangeSum(2, 5), 4e18, 10);
    }

    function test_cancellation_overlappingRangesPartialInverse() public {
        h.initAndSeed(uniformFactors(8));

        // Apply f=10 to [0,3]
        h.applyRangeFactor(0, 3, 10e18);

        // Apply f=0.1 to [2,5] -> partial cancellation on [2,3]
        h.applyRangeFactor(2, 5, 0.1e18);

        // Elements 0,1: 1 * 10 = 10
        // Elements 2,3: 1 * 10 * 0.1 = 1
        // Elements 4,5: 1 * 0.1 = 0.1
        // Elements 6,7: 1
        // Total: 20 + 2 + 0.2 + 2 = 24.2
        assertApproxEqAbs(h.getTotalSum(), 24.2e18, 100);

        // Subrange [2,3] should be back to ~2 WAD
        assertApproxEqAbs(h.getRangeSum(2, 3), 2e18, 10);
    }

    // ============================================================
    // Edge cases: flush threshold stress
    // ============================================================

    function test_flushStress_repeatedMaxFactor() public {
        h.initAndSeed(uniformFactors(4));

        // Apply MAX_FACTOR (100) multiple times to trigger flush
        for (uint256 i = 0; i < 5; i++) {
            h.applyRangeFactor(0, 3, MAX_FACTOR);
        }

        // Should not revert, total = 4 * 100^5 = 4e10 WAD
        uint256 total = h.getTotalSum();
        uint256 expected = 40_000_000_000e18; // 4e10 WAD
        assertApproxEqAbs(total, expected, expected / 100); // 1% tolerance
    }

    function test_flushStress_repeatedMinFactor() public {
        // Start with larger values to avoid zero
        uint256[] memory factors = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            factors[i] = 1_000_000e18;
        }
        h.initAndSeed(factors);

        // Apply MIN_FACTOR (0.01) multiple times to trigger flush
        for (uint256 i = 0; i < 5; i++) {
            h.applyRangeFactor(0, 3, MIN_FACTOR);
        }

        // Should not revert
        uint256 total = h.getTotalSum();
        // 4 * 1e6 * 0.01^5 = 4e6 * 1e-10 = 4e-4 WAD per bin... but we need to compute in WAD math
        // expected = 4_000_000e18 * (0.01e18)^5 / (1e18)^5
        // = 4_000_000e18 * 1e-10 = 0.0004e18 = 4e14
        uint256 expected = 4e14;
        assertApproxEqAbs(total, expected, expected / 10 + 1); // Allow larger tolerance for small values
    }

    function test_flushStress_alternatingMaxAndMinFactors() public {
        h.initAndSeed(uniformFactors(4));

        // Alternating: should roughly cancel out
        for (uint256 i = 0; i < 3; i++) {
            h.applyRangeFactor(0, 3, MAX_FACTOR); // *100
            h.applyRangeFactor(0, 3, MIN_FACTOR); // *0.01
        }

        // Net effect: (100 * 0.01)^3 = 1^3 = 1
        assertApproxEqAbs(h.getTotalSum(), 4e18, 100);
    }

    // ============================================================
    // Edge cases: view vs state-changing query consistency
    // ============================================================

    function test_viewVsStateChanging_matchesPropagated() public {
        h.initAndSeed(uniformFactors(8));

        // Apply some factors
        h.applyRangeFactor(0, 3, TWO_WAD);
        h.applyRangeFactor(2, 5, 3e18);

        // View query
        uint256 viewSum = h.getRangeSum(1, 4);

        // State-changing query (propagateLazy) - use staticcall via this trick:
        // Call propagateLazy which returns the same sum but also flushes lazy tags
        uint256 propagatedSum = h.propagateLazy(1, 4);

        assertEq(viewSum, propagatedSum);
    }

    function test_viewVsStateChanging_unchangedAfterPropagate() public {
        h.initAndSeed(uniformFactors(8));

        h.applyRangeFactor(0, 7, TWO_WAD);

        uint256 viewBefore = h.getRangeSum(2, 5);
        h.propagateLazy(2, 5);
        uint256 viewAfter = h.getRangeSum(2, 5);

        assertEq(viewAfter, viewBefore);
    }

    function test_viewVsStateChanging_propagateIdempotent() public {
        h.initAndSeed(uniformFactors(8));

        h.applyRangeFactor(0, 7, 5e18);

        uint256 first = h.propagateLazy(0, 7);
        uint256 second = h.propagateLazy(0, 7);
        uint256 third = h.propagateLazy(0, 7);

        assertEq(first, second);
        assertEq(second, third);
    }

    // ============================================================
    // Property: naive model comparison
    // ============================================================

    function test_naiveModel_matchesAfterRandomOperations() public {
        uint32 size = 16;
        h.initAndSeed(uniformFactors(size));

        // Naive model: array of values
        uint256[] memory naive = new uint256[](size);
        for (uint32 i = 0; i < size; i++) {
            naive[i] = WAD;
        }

        Prng memory prng = createPrng(777);

        // Apply 20 random range operations
        for (uint256 op = 0; op < 20; op++) {
            uint32 lo = nextInt(prng, size);
            uint32 hi = lo + nextInt(prng, size - lo);
            uint256 factor = nextInRange(prng, MIN_FACTOR, MAX_FACTOR);

            // Apply to segment tree
            h.applyRangeFactor(lo, hi, factor);

            // Apply to naive model
            for (uint32 i = lo; i <= hi; i++) {
                naive[i] = wMulNearest(naive[i], factor);
            }
        }

        // Compare individual node values
        for (uint32 i = 0; i < size; i++) {
            uint256 treeVal = h.getNodeValue(i);
            // Allow 0.01% tolerance due to accumulated rounding differences
            uint256 tolerance = naive[i] / 10000 + 10;
            assertApproxEqAbs(treeVal, naive[i], tolerance);
        }

        // Compare total sum
        uint256 naiveTotal;
        for (uint32 i = 0; i < size; i++) {
            naiveTotal += naive[i];
        }
        uint256 treeTotal = h.getTotalSum();
        assertApproxEqAbs(treeTotal, naiveTotal, naiveTotal / 1000 + 100);
    }

    // ============================================================
    // Internal: shared fixture helpers
    // ============================================================

    /// @dev Seeds a 4-element uniform tree [1, 1, 1, 1] WAD.
    function _seedUniform4() internal {
        h.initAndSeed(uniformFactors(4));
    }
}
