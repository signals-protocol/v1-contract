// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../modules/trade/lib/ExposureDiffLib.sol";

/// @notice Test harness for ExposureDiffLib library.
/// @dev Exposes diff array operations for unit testing.
contract ExposureDiffLibHarness {
    mapping(uint32 => int256) private diff;

    /// @notice Add delta to range [lo, hi] inclusive
    function rangeAdd(uint32 lo, uint32 hi, int256 delta, uint32 numBins) external {
        ExposureDiffLib.rangeAdd(diff, lo, hi, delta, numBins);
    }

    /// @notice Query exposure at a specific bin
    function pointQuery(uint32 bin) external view returns (uint256) {
        return ExposureDiffLib.pointQuery(diff, bin);
    }

    /// @notice Query raw prefix sum at a bin
    function rawPrefixSum(uint32 bin) external view returns (int256) {
        return ExposureDiffLib.rawPrefixSum(diff, bin);
    }

    /// @notice Get diff value at specific bin (for testing)
    function getDiff(uint32 bin) external view returns (int256) {
        return diff[bin];
    }

    /// @notice Reset diff array (for test isolation)
    function reset(uint32 numBins) external {
        for (uint32 i = 0; i < numBins; i++) {
            delete diff[i];
        }
    }
}

