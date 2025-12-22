// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../modules/trade/lib/TickBinLib.sol";

/// @notice Test harness for TickBinLib library.
/// @dev Exposes tick-bin conversion functions for unit testing.
contract TickBinLibHarness {
    /// @notice Convert a single tick to bin index
    function tickToBin(
        int256 minTick,
        int256 tickSpacing,
        uint32 numBins,
        int256 tick
    ) external pure returns (uint32) {
        return TickBinLib.tickToBin(minTick, tickSpacing, numBins, tick);
    }

    /// @notice Convert tick range to bin range
    function ticksToBins(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint32 numBins,
        int256 lowerTick,
        int256 upperTick
    ) external pure returns (uint32 loBin, uint32 hiBin) {
        return TickBinLib.ticksToBins(minTick, maxTick, tickSpacing, numBins, lowerTick, upperTick);
    }
}

