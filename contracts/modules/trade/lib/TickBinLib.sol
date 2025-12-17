// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../interfaces/ISignalsCore.sol";
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
     * @param market Market struct containing minTick, tickSpacing, numBins
     * @param tick The tick value to convert (must be aligned to tickSpacing)
     * @return bin The 0-based bin index
     */
    function tickToBin(
        ISignalsCore.Market memory market,
        int256 tick
    ) internal pure returns (uint32 bin) {
        int256 offset = tick - market.minTick;
        
        // Tick must be >= minTick and aligned to tickSpacing
        if (offset < 0 || offset % market.tickSpacing != 0) {
            revert CLMSRErrors.InvalidTick(tick, market.minTick, market.maxTick);
        }
        
        bin = uint32(uint256(offset / market.tickSpacing));
        
        // Bin must be within valid range
        if (bin >= market.numBins) {
            revert CLMSRErrors.RangeBinsOutOfBounds(bin, bin, market.numBins);
        }
    }

    /**
     * @notice Convert tick range [lowerTick, upperTick) to inclusive bin range [loBin, hiBin]
     * @dev lowerTick is inclusive, upperTick is exclusive (standard range convention)
     * @param market Market struct containing minTick, maxTick, tickSpacing, numBins
     * @param lowerTick Lower bound (inclusive)
     * @param upperTick Upper bound (exclusive)
     * @return loBin Lower bin index (inclusive)
     * @return hiBin Upper bin index (inclusive)
     */
    function ticksToBins(
        ISignalsCore.Market memory market,
        int256 lowerTick,
        int256 upperTick
    ) internal pure returns (uint32 loBin, uint32 hiBin) {
        // Validate tick range
        if (lowerTick >= upperTick) {
            revert CLMSRErrors.InvalidTickRange(lowerTick, upperTick);
        }
        if (lowerTick < market.minTick) {
            revert CLMSRErrors.InvalidTick(lowerTick, market.minTick, market.maxTick);
        }
        if (upperTick > market.maxTick + market.tickSpacing) {
            revert CLMSRErrors.InvalidTick(upperTick, market.minTick, market.maxTick);
        }
        
        // Check alignment
        if ((lowerTick - market.minTick) % market.tickSpacing != 0) {
            revert CLMSRErrors.InvalidTickSpacing(lowerTick, market.tickSpacing);
        }
        if ((upperTick - market.minTick) % market.tickSpacing != 0) {
            revert CLMSRErrors.InvalidTickSpacing(upperTick, market.tickSpacing);
        }
        
        // Convert to 0-based bin indices
        // lowerTick → loBin (inclusive)
        loBin = uint32(uint256((lowerTick - market.minTick) / market.tickSpacing));
        
        // upperTick → hiBin (exclusive → inclusive, so -1)
        // upperTick is exclusive, so bin = (upperTick - minTick) / tickSpacing - 1
        hiBin = uint32(uint256((upperTick - market.minTick) / market.tickSpacing)) - 1;
        
        // Validate bin range
        if (loBin > hiBin) {
            revert CLMSRErrors.InvalidRangeBins(loBin, hiBin);
        }
        if (hiBin >= market.numBins) {
            revert CLMSRErrors.RangeBinsOutOfBounds(loBin, hiBin, market.numBins);
        }
    }

    // ============================================================
    // Primitives-based overloads (gas optimization: no Market memory copy)
    // ============================================================

    /**
     * @notice Convert a single tick to bin index (primitives version)
     * @dev Avoids Market memory copy for gas optimization
     * @param minTick Market minimum tick
     * @param tickSpacing Market tick spacing
     * @param numBins Market number of bins
     * @param tick The tick value to convert (must be aligned to tickSpacing)
     * @return bin The 0-based bin index
     */
    function tickToBinPrim(
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
     * @notice Convert tick range to inclusive bin range (primitives version)
     * @dev Avoids Market memory copy for gas optimization
     *      Assumes tick range already validated by caller
     * @param minTick Market minimum tick
     * @param maxTick Market maximum tick
     * @param tickSpacing Market tick spacing
     * @param numBins Market number of bins
     * @param lowerTick Lower bound (inclusive)
     * @param upperTick Upper bound (exclusive)
     * @return loBin Lower bin index (inclusive)
     * @return hiBin Upper bin index (inclusive)
     */
    function ticksToBinsPrim(
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

