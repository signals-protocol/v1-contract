// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../base/HarnessDeployer.sol";
import "../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";

/// @title SegmentTreeHandler
/// @notice Stateful handler for Foundry invariant testing of LazyMulSegmentTree.
/// @dev Three operations with try/catch — tracks ghost variables for invariant checks.
contract SegmentTreeHandler is Test {
    LazyMulSegmentTreeHarness public harness;

    uint32 constant SIZE = 80;
    uint256 constant MIN_FACTOR = 0.01e18;
    uint256 constant MAX_FACTOR = 100e18;
    bytes4 constant PANIC_SELECTOR = 0x4e487b71;

    // Ghost variables
    uint256 public opCount;
    bool public panicOccurred;

    constructor(LazyMulSegmentTreeHarness _harness) {
        harness = _harness;
    }

    /// @notice Apply a random bounded factor to a random bounded range.
    function applyRandomFactor(uint32 rawLo, uint32 rawHi, uint256 rawFactor) external {
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));
        uint256 factor = bound(rawFactor, MIN_FACTOR, MAX_FACTOR);

        try harness.applyRangeFactor(lo, hi, factor) {
            opCount++;
        } catch (bytes memory reason) {
            _checkPanic(reason);
        }
    }

    /// @notice Apply MAX_FACTOR to stress flush threshold.
    function applyMaxFactor(uint32 rawLo, uint32 rawHi) external {
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));

        try harness.applyRangeFactor(lo, hi, MAX_FACTOR) {
            opCount++;
        } catch (bytes memory reason) {
            _checkPanic(reason);
        }
    }

    /// @notice Apply MIN_FACTOR to stress underflow flush.
    function applyMinFactor(uint32 rawLo, uint32 rawHi) external {
        uint32 lo = uint32(bound(uint256(rawLo), 0, SIZE - 1));
        uint32 hi = uint32(bound(uint256(rawHi), lo, SIZE - 1));

        try harness.applyRangeFactor(lo, hi, MIN_FACTOR) {
            opCount++;
        } catch (bytes memory reason) {
            _checkPanic(reason);
        }
    }

    function _checkPanic(bytes memory reason) internal {
        if (reason.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 32))
            }
            if (selector == PANIC_SELECTOR) {
                panicOccurred = true;
            }
        }
    }
}

/// @title LazyMulSegmentTreeInvariantTest
/// @notice 5 stateful invariant tests (I1–I5) for LazyMulSegmentTree.
/// @dev Handler restricts fuzzer to bounded applyRangeFactor operations on an 80-bin tree.
contract LazyMulSegmentTreeInvariantTest is HarnessDeployer {
    LazyMulSegmentTreeHarness h;
    SegmentTreeHandler handler;

    uint32 constant SIZE = 80;

    function setUp() public override {
        super.setUp();

        h = deployLazyMulSegmentTreeHarness();
        h.initAndSeed(uniformFactors(SIZE));

        handler = new SegmentTreeHandler(h);
        targetContract(address(handler));
    }

    // ============================================================
    // I1: Total sum is always positive
    // ============================================================

    function invariant_totalSumPositive() public view {
        assertGt(h.getTotalSum(), 0, "I1: totalSum must be > 0");
    }

    // ============================================================
    // I2: Total sum ≈ full range sum
    // ============================================================

    function invariant_totalSumEqFullRangeSum() public view {
        uint256 totalSum = h.getTotalSum();
        uint256 rangeSum = h.getRangeSum(0, SIZE - 1);
        assertApproxEqAbs(totalSum, rangeSum, 80, "I2: totalSum != getRangeSum(0,79)");
    }

    // ============================================================
    // I3: Total sum ≈ sum of all leaf values
    // ============================================================

    function invariant_totalSumEqLeafSum() public view {
        uint256 totalSum = h.getTotalSum();
        uint256 leafSum;
        for (uint32 i = 0; i < SIZE; i++) {
            leafSum += h.getNodeValue(i);
        }
        // SIG-596: raised flush threshold (1e21 → 1e45) allows more pending
        // accumulation before flush, which compounds wMulNearest rounding
        // over extreme MAX_FACTOR/MIN_FACTOR stress sequences. Observed
        // worst-case relative drift ~2e-8 under CI invariant fuzzing.
        // Tolerance widened from 1e-10 to 1e-6 (50× margin over worst case).
        uint256 tolerance = 1e12 + totalSum / 1e6;
        assertApproxEqAbs(totalSum, leafSum, tolerance, "I3: totalSum != leafSum");
    }

    // ============================================================
    // I4: No bin overflows — each bin value ≤ totalSum
    // ============================================================

    /// @dev Under extreme repeated MIN_FACTOR (0.01) stress, bins may legitimately
    /// round to 0 in WAD math. The structural invariant is that no single bin
    /// overflows to exceed totalSum (which would indicate corruption).
    function invariant_allBinsNoOverflow() public view {
        uint256 totalSum = h.getTotalSum();
        for (uint32 i = 0; i < SIZE; i++) {
            assertLe(h.getNodeValue(i), totalSum + 1, "I4: bin value exceeds totalSum");
        }
    }

    // ============================================================
    // I5: No Panic(uint256) ever occurred
    // ============================================================

    function invariant_noPanic() public view {
        assertFalse(handler.panicOccurred(), "I5: Panic(uint256) detected in handler");
    }
}
