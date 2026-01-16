// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LazyMulSegmentTree} from "../lib/LazyMulSegmentTree.sol";
import {FixedPointMathU} from "../lib/FixedPointMathU.sol";

/// @notice Test harness for LazyMulSegmentTree library.
/// @dev Exposes all tree operations for unit testing.
contract LazyMulSegmentTreeHarness {
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;

    error EmptyFactors();

    LazyMulSegmentTree.Tree private tree;

    uint256 public constant ONE_WAD = 1e18;
    uint256 public constant MIN_FACTOR = LazyMulSegmentTree.MIN_FACTOR;
    uint256 public constant MAX_FACTOR = LazyMulSegmentTree.MAX_FACTOR;

    function init(uint32 size) external {
        // Reset entire tree struct for re-initialization (dense version)
        delete tree;
        tree.init(size);
    }

    function getTreeSize() external view returns (uint32) {
        return tree.size;
    }

    function applyRangeFactor(uint32 lo, uint32 hi, uint256 factor) external {
        tree.applyRangeFactor(lo, hi, factor);
    }

    function getRangeSum(uint32 lo, uint32 hi) external view returns (uint256) {
        return tree.getRangeSum(lo, hi);
    }

    function getTotalSum() external view returns (uint256) {
        if (tree.size == 0) return 0;
        return tree.totalSum();
    }

    function getNodeValue(uint32 index) external view returns (uint256) {
        return tree.getRangeSum(index, index);
    }

    /// @notice Seed tree with explicit factors (for testing).
    function seedWithFactors(uint256[] calldata factors) external {
        tree.seedWithFactors(factors);
    }

    /// @notice Initialize and seed in one call.
    function initAndSeed(uint256[] calldata factors) external {
        if (factors.length == 0) revert EmptyFactors();
        // Reset entire tree struct (dense version)
        delete tree;
        tree.init(uint32(factors.length));
        tree.seedWithFactors(factors);
    }

    /// @notice Propagate lazy values and return range sum (state-changing).
    function propagateLazy(uint32 lo, uint32 hi) external returns (uint256) {
        return tree.propagateLazy(lo, hi);
    }
}



