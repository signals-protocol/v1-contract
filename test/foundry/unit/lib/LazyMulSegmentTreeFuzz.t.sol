// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";

/// @title LazyMulSegmentTreeFuzzTest
/// @notice 12 stateless fuzz tests (F1–F12) for LazyMulSegmentTree.
/// @dev Uses 80-bin trees (depth 7) for adequate lazy propagation coverage at lower gas.
contract LazyMulSegmentTreeFuzzTest is HarnessDeployer {
    LazyMulSegmentTreeHarness h;

    uint32 constant SIZE = 80;
    bytes4 constant PANIC_SELECTOR = 0x4e487b71;

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

    function _initUniform() internal {
        h.initAndSeed(uniformFactors(SIZE));
    }

    function _applyRandomOps(Prng memory prng, uint256 ops) internal {
        for (uint256 i = 0; i < ops; i++) {
            uint32 lo = uint32(bound(uint256(nextRand(prng)), 0, SIZE - 1));
            uint32 hi = uint32(bound(uint256(nextRand(prng)), lo, SIZE - 1));
            uint256 factor = bound(uint256(nextRand(prng)), MIN_FACTOR, MAX_FACTOR);
            h.applyRangeFactor(lo, hi, factor);
        }
    }

    function _leafSum() internal view returns (uint256 sum) {
        for (uint32 i = 0; i < SIZE; i++) {
            sum += h.getNodeValue(i);
        }
    }

    // ============================================================
    // F1: Sum Consistency — totalSum ≈ Σ getNodeValue(i)
    // ============================================================

    function testFuzz_sumConsistency_totalEqLeafSum(uint64 seed, uint8 rawOps) public {
        _initUniform();
        uint256 ops = bound(uint256(rawOps), 5, 50);
        Prng memory prng = createPrng(seed);
        _applyRandomOps(prng, ops);

        uint256 totalSum = h.getTotalSum();
        uint256 leafSum = _leafSum();
        uint256 tolerance = 1e12 + totalSum / 1e12;

        assertApproxEqAbs(totalSum, leafSum, tolerance, "F1: totalSum != leafSum");
    }

    // ============================================================
    // F2: Sum Consistency — totalSum ≈ getRangeSum(0, 79)
    // ============================================================

    function testFuzz_sumConsistency_totalEqFullRangeSum(uint64 seed, uint8 rawOps) public {
        _initUniform();
        uint256 ops = bound(uint256(rawOps), 5, 50);
        Prng memory prng = createPrng(seed);
        _applyRandomOps(prng, ops);

        uint256 totalSum = h.getTotalSum();
        uint256 rangeSum = h.getRangeSum(0, SIZE - 1);

        assertApproxEqAbs(totalSum, rangeSum, 80, "F2: totalSum != getRangeSum(0,79)");
    }

    // ============================================================
    // F3: Sum Consistency — sub-ranges additive
    // ============================================================

    function testFuzz_sumConsistency_subRangesAdditive(uint64 seed, uint8 rawOps, uint32 rawMid) public {
        _initUniform();
        uint256 ops = bound(uint256(rawOps), 5, 50);
        Prng memory prng = createPrng(seed);
        _applyRandomOps(prng, ops);

        uint32 mid = uint32(bound(uint256(rawMid), 1, SIZE - 2));
        uint256 left = h.getRangeSum(0, mid);
        uint256 right = h.getRangeSum(mid + 1, SIZE - 1);
        uint256 full = h.getRangeSum(0, SIZE - 1);

        assertApproxEqAbs(left + right, full, full / 1e12 + SIZE, "F3: subranges not additive");
    }

    // ============================================================
    // F4: Monotonicity — factor > 1 strictly increases range sum
    // ============================================================

    function testFuzz_monotonicity_factorGt1(uint32 rawLo, uint32 rawHi, uint256 rawFactor) public {
        _initUniform();
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));
        uint256 factor = bound(rawFactor, WAD + 1, MAX_FACTOR);

        uint256 sumBefore = h.getRangeSum(lo, hi);
        h.applyRangeFactor(lo, hi, factor);
        uint256 sumAfter = h.getRangeSum(lo, hi);

        assertGt(sumAfter, sumBefore, "F4: factor > 1 must increase range sum");
    }

    // ============================================================
    // F5: Monotonicity — factor < 1 strictly decreases range sum
    // ============================================================

    function testFuzz_monotonicity_factorLt1(uint32 rawLo, uint32 rawHi, uint256 rawFactor) public {
        _initUniform();
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));
        uint256 factor = bound(rawFactor, MIN_FACTOR, WAD - 1);

        uint256 sumBefore = h.getRangeSum(lo, hi);
        h.applyRangeFactor(lo, hi, factor);
        uint256 sumAfter = h.getRangeSum(lo, hi);

        assertLt(sumAfter, sumBefore, "F5: factor < 1 must decrease range sum");
    }

    // ============================================================
    // F6: Range Isolation — bins outside [lo,hi] unchanged
    // ============================================================

    function testFuzz_rangeIsolation(uint32 rawLo, uint32 rawHi, uint256 rawFactor) public {
        _initUniform();
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));
        uint256 factor = bound(rawFactor, MIN_FACTOR, MAX_FACTOR);

        // Record all bin values before
        uint256[] memory beforeValues = new uint256[](SIZE);
        for (uint32 i = 0; i < SIZE; i++) {
            beforeValues[i] = h.getNodeValue(i);
        }

        h.applyRangeFactor(lo, hi, factor);

        // Bins outside [lo,hi] must be unchanged (exact equality on fresh uniform tree)
        for (uint32 i = 0; i < SIZE; i++) {
            if (i < lo || i > hi) {
                assertEq(h.getNodeValue(i), beforeValues[i], "F6: bin outside range changed");
            }
        }
    }

    // ============================================================
    // F7: Cancellation — apply factor, then WAD^2/factor
    // ============================================================

    function testFuzz_cancellation(uint32 rawLo, uint32 rawHi, uint256 rawFactor) public {
        _initUniform();
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));
        uint256 factor = bound(rawFactor, MIN_FACTOR, MAX_FACTOR);

        uint256 totalBefore = h.getTotalSum();

        h.applyRangeFactor(lo, hi, factor);

        // Inverse: WAD^2 / factor is always in [MIN_FACTOR, MAX_FACTOR]
        uint256 inverse = (WAD * WAD) / factor;
        h.applyRangeFactor(lo, hi, inverse);

        uint256 totalAfter = h.getTotalSum();
        uint256 tolerance = totalBefore / 1e12 + 100;

        assertApproxEqAbs(totalAfter, totalBefore, tolerance, "F7: cancellation failed");
    }

    // ============================================================
    // F8: View == Propagate
    // ============================================================

    function testFuzz_viewEqPropagate(uint64 seed, uint8 rawOps, uint32 rawLo, uint32 rawHi) public {
        _initUniform();
        uint256 ops = bound(uint256(rawOps), 5, 50);
        Prng memory prng = createPrng(seed);
        _applyRandomOps(prng, ops);

        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));

        uint256 viewSum = h.getRangeSum(lo, hi);
        uint256 propagatedSum = h.propagateLazy(lo, hi);
        uint256 tolerance = viewSum / 1e12 + SIZE;

        assertApproxEqAbs(viewSum, propagatedSum, tolerance, "F8: view != propagate");
    }

    // ============================================================
    // F9: Naive Model — tree vs array on 16 bins with ~30 ops
    // ============================================================

    function testFuzz_naiveModel(uint64 seed) public {
        uint32 size = 16;
        h.initAndSeed(uniformFactors(size));

        uint256[] memory naive = new uint256[](size);
        for (uint32 i = 0; i < size; i++) {
            naive[i] = WAD;
        }

        Prng memory prng = createPrng(seed);

        for (uint256 op = 0; op < 30; op++) {
            uint32 lo = nextInt(prng, size);
            uint32 hi = lo + nextInt(prng, size - lo);
            uint256 factor = nextInRange(prng, MIN_FACTOR, MAX_FACTOR);

            h.applyRangeFactor(lo, hi, factor);

            for (uint32 i = lo; i <= hi; i++) {
                naive[i] = wMulNearest(naive[i], factor);
            }
        }

        // Per-element comparison
        for (uint32 i = 0; i < size; i++) {
            uint256 treeVal = h.getNodeValue(i);
            uint256 tolerance = naive[i] / 10000 + 10;
            assertApproxEqAbs(treeVal, naive[i], tolerance, "F9: tree != naive per element");
        }

        // Total sum comparison
        uint256 naiveTotal;
        for (uint32 i = 0; i < size; i++) {
            naiveTotal += naive[i];
        }
        uint256 treeTotal = h.getTotalSum();
        assertApproxEqAbs(treeTotal, naiveTotal, naiveTotal / 1000 + 100, "F9: tree != naive total");
    }

    // ============================================================
    // F10: No Panic — custom reverts OK, Panic(uint256) forbidden
    // ============================================================

    function testFuzz_noPanic(uint64 seed, uint8 rawOps) public {
        _initUniform();
        uint256 ops = bound(uint256(rawOps), 5, 50);
        Prng memory prng = createPrng(seed);

        for (uint256 i = 0; i < ops; i++) {
            uint32 lo = uint32(bound(uint256(nextRand(prng)), 0, SIZE - 1));
            uint32 hi = uint32(bound(uint256(nextRand(prng)), lo, SIZE - 1));
            uint256 factor = bound(uint256(nextRand(prng)), MIN_FACTOR, MAX_FACTOR);

            try h.applyRangeFactor(lo, hi, factor) {} catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 selector;
                    assembly {
                        selector := mload(add(reason, 32))
                    }
                    assertTrue(selector != PANIC_SELECTOR, "F10: Panic(uint256) detected");
                }
            }
        }
    }

    // ============================================================
    // F11: Flush Stress — alternating MAX/MIN factors
    // ============================================================

    function testFuzz_flushStress(uint64 seed, uint8 rawReps) public {
        _initUniform();
        uint256 reps = bound(uint256(rawReps), 5, 30);
        Prng memory prng = createPrng(seed);

        for (uint256 i = 0; i < reps; i++) {
            uint32 lo = uint32(bound(uint256(nextRand(prng)), 0, SIZE - 1));
            uint32 hi = uint32(bound(uint256(nextRand(prng)), lo, SIZE - 1));
            uint256 factor = (i % 2 == 0) ? MAX_FACTOR : MIN_FACTOR;

            try h.applyRangeFactor(lo, hi, factor) {} catch {}
        }

        uint256 totalSum = h.getTotalSum();
        assertGt(totalSum, 0, "F11: totalSum must be > 0 after flush stress");

        uint256 leafSum = _leafSum();
        uint256 tolerance = 1e12 + totalSum / 1e12;
        assertApproxEqAbs(totalSum, leafSum, tolerance, "F11: sum consistency after flush stress");
    }

    // ============================================================
    // F12: Seed Correctness — totalSum == Σ factors (exact)
    // ============================================================

    function testFuzz_seedWithFactors(uint64 seed) public {
        Prng memory prng = createPrng(seed);
        uint256[] memory factors = randomFactors(prng, SIZE, MIN_FACTOR, MAX_FACTOR);

        h.initAndSeed(factors);

        uint256 expectedTotal;
        for (uint32 i = 0; i < SIZE; i++) {
            expectedTotal += factors[i];
        }

        assertEq(h.getTotalSum(), expectedTotal, "F12: totalSum != sum of seed factors");
    }
}
