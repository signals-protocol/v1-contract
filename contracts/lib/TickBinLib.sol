// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/ISignalsCore.sol";

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
        require(offset >= 0, "TickBin: tick below minTick");
        require(offset % market.tickSpacing == 0, "TickBin: tick not aligned");
        
        bin = uint32(uint256(offset / market.tickSpacing));
        
        // Bin must be within valid range
        require(bin < market.numBins, "TickBin: bin out of bounds");
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
        require(lowerTick < upperTick, "TickBin: invalid tick range");
        require(lowerTick >= market.minTick, "TickBin: lower tick below minTick");
        require(upperTick <= market.maxTick + market.tickSpacing, "TickBin: upper tick above maxTick");
        
        // Check alignment
        require((lowerTick - market.minTick) % market.tickSpacing == 0, "TickBin: lower tick not aligned");
        require((upperTick - market.minTick) % market.tickSpacing == 0, "TickBin: upper tick not aligned");
        
        // Convert to 0-based bin indices
        // lowerTick → loBin (inclusive)
        loBin = uint32(uint256((lowerTick - market.minTick) / market.tickSpacing));
        
        // upperTick → hiBin (exclusive → inclusive, so -1)
        // upperTick is exclusive, so bin = (upperTick - minTick) / tickSpacing - 1
        hiBin = uint32(uint256((upperTick - market.minTick) / market.tickSpacing)) - 1;
        
        // Validate bin range
        require(loBin <= hiBin, "TickBin: invalid bin range");
        require(hiBin < market.numBins, "TickBin: hiBin out of bounds");
    }
}

