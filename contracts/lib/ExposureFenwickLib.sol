// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ExposureFenwickLib
 * @notice Fenwick Tree (Binary Indexed Tree) for efficient exposure tracking
 * @dev Implements diff-array + prefix-sum pattern for O(log n) range updates and point queries
 *
 * Data structure:
 *   - Uses 1-based indexing (Fenwick convention)
 *   - Bins are 0-based externally, converted to 1-based internally
 *   - Stores diff values (not actual exposures) for range update efficiency
 *
 * Operations:
 *   - rangeAdd([loBin, hiBin], delta): O(log n) - add delta to all bins in range
 *   - pointQuery(bin): O(log n) - get current exposure at specific bin
 *
 * Invariant:
 *   - Final exposure at any bin must be >= 0 (enforced at query time)
 */
library ExposureFenwickLib {
    // ============================================================
    // Core Fenwick Operations (1-based indexing)
    // ============================================================

    /**
     * @dev Add delta to a single position in the Fenwick tree
     * @param tree The Fenwick tree storage mapping (1-based index → diff value)
     * @param idx 1-based index to update
     * @param delta Value to add (can be negative)
     * @param size Number of bins (tree size)
     */
    function _add(
        mapping(uint32 => int256) storage tree,
        uint32 idx,
        int256 delta,
        uint32 size
    ) private {
        while (idx <= size) {
            tree[idx] += delta;
            unchecked {
                idx += idx & uint32(0 - int32(idx)); // idx += lowbit(idx)
            }
        }
    }

    /**
     * @dev Compute prefix sum from index 1 to idx (inclusive)
     * @param tree The Fenwick tree storage mapping
     * @param idx 1-based index (inclusive upper bound)
     * @return sum Prefix sum value
     */
    function _prefixSum(
        mapping(uint32 => int256) storage tree,
        uint32 idx
    ) private view returns (int256 sum) {
        while (idx > 0) {
            sum += tree[idx];
            unchecked {
                idx -= idx & uint32(0 - int32(idx)); // idx -= lowbit(idx)
            }
        }
    }

    // ============================================================
    // Public API (0-based bin indexing)
    // ============================================================

    /**
     * @notice Add delta to all bins in range [loBin, hiBin] (inclusive, 0-based)
     * @dev Uses diff-array pattern:
     *      - add(loBin+1, +delta)
     *      - add(hiBin+2, -delta) if hiBin+2 <= numBins
     * @param tree The Fenwick tree storage mapping
     * @param loBin Lower bound (0-based, inclusive)
     * @param hiBin Upper bound (0-based, inclusive)
     * @param delta Value to add (can be negative for removal)
     * @param numBins Total number of bins in the market
     */
    function rangeAdd(
        mapping(uint32 => int256) storage tree,
        uint32 loBin,
        uint32 hiBin,
        int256 delta,
        uint32 numBins
    ) internal {
        require(loBin <= hiBin, "ExposureFenwick: invalid range");
        require(hiBin < numBins, "ExposureFenwick: bin out of bounds");

        // Convert to 1-based and apply diff-array pattern
        _add(tree, loBin + 1, delta, numBins);
        
        // Only add cancellation if within bounds
        if (hiBin + 2 <= numBins) {
            _add(tree, hiBin + 2, -delta, numBins);
        }
    }

    /**
     * @notice Get exposure at a specific bin (0-based)
     * @dev Exposure = prefixSum(bin+1) in the diff-array
     * @param tree The Fenwick tree storage mapping
     * @param bin Bin index (0-based)
     * @return exposure Current exposure at the bin (always >= 0)
     */
    function pointQuery(
        mapping(uint32 => int256) storage tree,
        uint32 bin
    ) internal view returns (uint256 exposure) {
        int256 sum = _prefixSum(tree, bin + 1);
        
        // Invariant: exposure must be non-negative
        // If negative, this indicates a bug (more removed than added)
        require(sum >= 0, "ExposureFenwick: negative exposure");
        
        return uint256(sum);
    }

    /**
     * @notice Get raw prefix sum at a specific bin (for debugging/testing)
     * @dev Returns signed value without non-negative check
     * @param tree The Fenwick tree storage mapping
     * @param bin Bin index (0-based)
     * @return sum Raw prefix sum (may be negative)
     */
    function rawPrefixSum(
        mapping(uint32 => int256) storage tree,
        uint32 bin
    ) internal view returns (int256 sum) {
        return _prefixSum(tree, bin + 1);
    }
}

