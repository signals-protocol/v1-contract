// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LazyMulSegmentTreeNoLink.sol";

contract LazyMulTreeTarget {
    using LazyMulSegmentTreeNoLink for LazyMulSegmentTreeNoLink.Tree;

    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_FACTOR = LazyMulSegmentTreeNoLink.MIN_FACTOR;
    uint256 public constant MAX_FACTOR = LazyMulSegmentTreeNoLink.MAX_FACTOR;

    LazyMulSegmentTreeNoLink.Tree private tree;
    uint32 public immutable size;

    constructor(uint32 treeSize) {
        require(treeSize > 0, "size=0");
        size = treeSize;

        tree.init(treeSize);

        uint256[] memory factors = new uint256[](treeSize);
        for (uint32 i = 0; i < treeSize; i++) {
            factors[uint256(i)] = WAD;
        }
        tree.seedWithFactors(factors);
    }

    function applyBounded(uint32 lo, uint32 hi, uint256 rawFactor) external {
        lo = uint32(uint256(lo) % uint256(size));
        hi = uint32(uint256(hi) % uint256(size));
        if (lo > hi) {
            (lo, hi) = (hi, lo);
        }

        uint256 factorSpan = MAX_FACTOR - MIN_FACTOR + 1;
        uint256 factor = MIN_FACTOR + (rawFactor % factorSpan);
        tree.applyRangeFactor(lo, hi, factor);
    }

    function tryApplyBounded(
        uint32 lo,
        uint32 hi,
        uint256 rawFactor
    ) external returns (bool ok, bytes4 selector) {
        try this.applyBounded(lo, hi, rawFactor) {
            return (true, bytes4(0));
        } catch (bytes memory err) {
            bytes4 sel = bytes4(0);
            if (err.length >= 4) {
                assembly ("memory-safe") {
                    sel := mload(add(err, 32))
                }
            }
            return (false, sel);
        }
    }

    function totalSum() external view returns (uint256) {
        return tree.totalSum();
    }

    function fullRangeSum() external view returns (uint256) {
        return tree.getRangeSum(0, size - 1);
    }

    function leafSum() external view returns (uint256 sum) {
        for (uint32 i = 0; i < size; i++) {
            sum += tree.getRangeSum(i, i);
        }
    }

    function driftTotalVsLeaf() external view returns (uint256) {
        uint256 total = tree.totalSum();
        uint256 leaves = this.leafSum();
        return total > leaves ? total - leaves : leaves - total;
    }

    function driftTotalVsFullRange() external view returns (uint256) {
        uint256 total = tree.totalSum();
        uint256 rangeSum = tree.getRangeSum(0, size - 1);
        return total > rangeSum ? total - rangeSum : rangeSum - total;
    }

    /// @dev Apply MAX_FACTOR to a bounded range (for fuzz testing recursive flush).
    function applyMaxFactor(uint32 lo, uint32 hi) external {
        lo = uint32(uint256(lo) % uint256(size));
        hi = uint32(uint256(hi) % uint256(size));
        if (lo > hi) {
            (lo, hi) = (hi, lo);
        }
        tree.applyRangeFactor(lo, hi, MAX_FACTOR);
    }

    function tryApplyMaxFactor(uint32 lo, uint32 hi) external returns (bool ok, bytes4 selector) {
        try this.applyMaxFactor(lo, hi) {
            return (true, bytes4(0));
        } catch (bytes memory err) {
            bytes4 sel = bytes4(0);
            if (err.length >= 4) {
                assembly ("memory-safe") {
                    sel := mload(add(err, 32))
                }
            }
            return (false, sel);
        }
    }
}
