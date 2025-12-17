// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../errors/CLMSRErrors.sol";

/**
 * @title TickBinLib
 * @notice Library for converting between ticks and bin indices
 * @dev Centralizes tick-to-bin conversion logic used across modules
 *
 * Tick System:
 *   - Market has range [minTick, maxTick] with tickSpacing
 *   - Bins are 0-based indices: bin = (tick - minTick) / tickSpacing
 *   - Total bins = numBins (set at market creation)
 *
 * Trade Ranges:
 *   - Positions use [lowerTick, upperTick) convention (lower inclusive, upper exclusive)
 *   - Converted to [loBin, hiBin] inclusive for internal operations
 */
library TickBinLib {
    /**
     * @notice Convert a single tick to bin index
     * @param minTick Market minimum tick
     * @param tickSpacing Market tick spacing
     * @param numBins Market number of bins
     * @param tick The tick value to convert (must be aligned to tickSpacing)
     * @return bin The 0-based bin index
     */
    function tickToBin(
        int256 minTick,
        int256 tickSpacing,
        uint32 numBins,
        int256 tick
    ) internal pure returns (uint32 bin) {
        int256 offset = tick - minTick;

        // Tick must be >= minTick and aligned to tickSpacing
        if (offset < 0 || offset % tickSpacing != 0) {
            revert CLMSRErrors.InvalidTickSpacing(tick, tickSpacing);
        }

        bin = uint32(uint256(offset / tickSpacing));

        // Bin must be within valid range
        if (bin >= numBins) {
            revert CLMSRErrors.RangeBinsOutOfBounds(bin, bin, numBins);
        }
    }

    /**
     * @notice Convert tick range [lowerTick, upperTick) to inclusive bin range [loBin, hiBin]
     * @dev lowerTick is inclusive, upperTick is exclusive (standard range convention)
     * @param minTick Market minimum tick
     * @param maxTick Market maximum tick
     * @param tickSpacing Market tick spacing
     * @param numBins Market number of bins
     * @param lowerTick Lower bound (inclusive)
     * @param upperTick Upper bound (exclusive)
     * @return loBin Lower bin index (inclusive)
     * @return hiBin Upper bin index (inclusive)
     */
    function ticksToBins(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint32 numBins,
        int256 lowerTick,
        int256 upperTick
    ) internal pure returns (uint32 loBin, uint32 hiBin) {
        // Validate tick range
        if (lowerTick >= upperTick) {
            revert CLMSRErrors.InvalidTickRange(lowerTick, upperTick);
        }
        if (lowerTick < minTick) {
            revert CLMSRErrors.InvalidTick(lowerTick, minTick, maxTick);
        }
        if (upperTick > maxTick + tickSpacing) {
            revert CLMSRErrors.InvalidTick(upperTick, minTick, maxTick);
        }

        // Check alignment
        if ((lowerTick - minTick) % tickSpacing != 0) {
            revert CLMSRErrors.InvalidTickSpacing(lowerTick, tickSpacing);
        }
        if ((upperTick - minTick) % tickSpacing != 0) {
            revert CLMSRErrors.InvalidTickSpacing(upperTick, tickSpacing);
        }

        // Convert to 0-based bin indices
        loBin = uint32(uint256((lowerTick - minTick) / tickSpacing));
        hiBin = uint32(uint256((upperTick - minTick) / tickSpacing)) - 1;

        // Validate bin range
        if (loBin > hiBin) {
            revert CLMSRErrors.InvalidRangeBins(loBin, hiBin);
        }
        if (hiBin >= numBins) {
            revert CLMSRErrors.RangeBinsOutOfBounds(loBin, hiBin, numBins);
        }
    }
}
