// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/HarnessDeployer.sol";

/// @notice Smoke tests proving the harness deployer and segment tree work correctly.
contract SegmentTreeBasicTest is HarnessDeployer {
    LazyMulSegmentTreeHarness internal tree;

    function setUp() public override {
        super.setUp();
        tree = deployLazyMulSegmentTreeHarness();
    }

    function test_initAndSeed_uniformDistribution() public {
        uint32 size = 8;
        tree.init(size);

        // Seed with uniform factors (all 1 WAD)
        uint256[] memory factors = uniformFactors(size);
        tree.initAndSeed(factors);

        // Total sum should be size * WAD
        uint256 totalSum = tree.getTotalSum();
        assertEq(totalSum, uint256(size) * WAD, "uniform total sum");

        // Each leaf should be WAD
        for (uint32 i = 0; i < size; i++) {
            uint256 leafSum = tree.getRangeSum(i, i);
            assertEq(leafSum, WAD, "leaf value");
        }
    }

    function test_applyFactor_updatesSum() public {
        uint32 size = 4;
        tree.init(size);
        tree.initAndSeed(uniformFactors(size));

        // Apply 2x factor to bins [1, 2]
        tree.applyRangeFactor(1, 2, TWO_WAD);

        // Bins 0 and 3 unchanged (1 WAD each)
        assertEq(tree.getRangeSum(0, 0), WAD, "bin 0 unchanged");
        assertEq(tree.getRangeSum(3, 3), WAD, "bin 3 unchanged");

        // Bins 1 and 2 doubled
        assertEq(tree.getRangeSum(1, 1), TWO_WAD, "bin 1 doubled");
        assertEq(tree.getRangeSum(2, 2), TWO_WAD, "bin 2 doubled");

        // Total = 1 + 2 + 2 + 1 = 6 WAD
        assertEq(tree.getTotalSum(), 6 * WAD, "total after factor");
    }

    function testFuzz_randomOps_sumPositive(uint64 seed) public {
        uint32 size = 16;
        tree.init(size);
        tree.initAndSeed(uniformFactors(size));

        Prng memory prng = createPrng(seed);

        // Apply 10 random factors
        for (uint256 i = 0; i < 10; i++) {
            uint32 lo = uint32(nextInRange(prng, 0, size));
            uint32 hi = uint32(nextInRange(prng, lo, size));
            // Factor between 0.5 WAD and 2 WAD
            uint256 factor = nextInRange(prng, HALF_WAD, TWO_WAD);
            tree.applyRangeFactor(lo, hi, factor);
        }

        // Invariant: total sum always positive after valid operations
        assertTrue(tree.getTotalSum() > 0, "sum stays positive");
    }
}
