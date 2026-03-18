// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/HarnessDeployer.sol";
import "../../../../contracts/testonly/LazyMulSegmentTreeHarness.sol";

/// @notice Gas benchmarks for LazyMulSegmentTree with recursive flush (SIG-294)
/// @dev Use `forge test --match-contract SegmentTreeGasBenchmark --gas-report` for detailed gas
contract SegmentTreeGasBenchmarkTest is HarnessDeployer {
    LazyMulSegmentTreeHarness h;
    uint32 constant NUM_BINS = 80;

    function setUp() public override {
        super.setUp();
        h = deployLazyMulSegmentTreeHarness();
        h.init(NUM_BINS);
    }

    // ============================================================
    // Full-range MAX_FACTOR applications
    // ============================================================

    function test_gas_1chunk() public {
        h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        assertGt(h.getTotalSum(), 0);
    }

    function test_gas_3chunks() public {
        for (uint256 i = 0; i < 3; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    function test_gas_5chunks() public {
        for (uint256 i = 0; i < 5; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    function test_gas_10chunks() public {
        for (uint256 i = 0; i < 10; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    function test_gas_15chunks() public {
        for (uint256 i = 0; i < 15; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    function test_gas_20chunks() public {
        for (uint256 i = 0; i < 20; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    function test_gas_25chunks() public {
        for (uint256 i = 0; i < 25; i++) {
            h.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        }
        assertGt(h.getTotalSum(), 0);
    }

    // ============================================================
    // Single-bin operations
    // ============================================================

    function test_gas_10singleBin() public {
        for (uint256 i = 0; i < 10; i++) {
            h.applyRangeFactor(0, 0, MAX_FACTOR);
        }
        assertGt(h.getRangeSum(0, 0), 0);
    }
}
