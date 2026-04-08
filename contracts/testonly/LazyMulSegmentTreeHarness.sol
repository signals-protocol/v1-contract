// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LazyMulSegmentTree} from "../lib/LazyMulSegmentTree.sol";
import {SignalsErrors as SE} from "../errors/SignalsErrors.sol";

/// @notice Test harness for LazyMulSegmentTree library.
/// @dev Exposes all tree operations for unit testing.
contract LazyMulSegmentTreeHarness {
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;

    error EmptyFactors();
    error SparseTreePath(uint32 binPosition);

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

    function setNodePending(uint32 nodeIndex, uint192 value) external {
        tree.nodes[nodeIndex].pendingFactor = value;
    }

    function getNodePending(uint32 nodeIndex) external view returns (uint192) {
        return tree.nodes[nodeIndex].pendingFactor;
    }

    function resolveLeafNodeIndex(uint32 binPosition) external view returns (uint32 nodeIndex) {
        if (tree.size == 0) revert SE.TreeNotInitialized();
        if (binPosition >= tree.size) revert SE.IndexOutOfBounds(binPosition, tree.size);

        uint32 l = 0;
        uint32 r = tree.size - 1;
        nodeIndex = tree.root;

        while (l < r) {
            (uint32 left, uint32 right) = _unpackChildPtr(tree.nodes[nodeIndex].childPtr);
            if (left == 0 || right == 0) revert SparseTreePath(binPosition);

            uint32 mid = l + (r - l) / 2;
            if (binPosition <= mid) {
                nodeIndex = left;
                r = mid;
            } else {
                nodeIndex = right;
                l = mid + 1;
            }
        }
    }

    function getRootIndex() external view returns (uint32) {
        return tree.root;
    }

    function _unpackChildPtr(uint64 packed) private pure returns (uint32 left, uint32 right) {
        left = uint32(packed >> 32);
        right = uint32(packed);
    }
}
