// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISignalsCore.sol";

library OracleTickLib {
    /// @dev Convert settlement value to a clamped, grid-aligned settlement tick.
    // Clamp then snap to the tick-spacing grid. Truncating the spacing division is the intended floor alignment,
    // and the second write reads the clamped tick through `offset` before assigning the aligned value.
    // slither-disable-start divide-before-multiply
    // slither-disable-start write-after-write
    function toSettlementTick(ISignalsCore.Market storage market, int256 settlementValue)
        internal
        view
        returns (int256)
    {
        int256 spacing = market.tickSpacing;
        int256 tick = settlementValue / int256(uint256(market.tickScale));

        // Clamp to valid range [minTick, maxTick - tickSpacing].
        int256 lastValidTick = market.maxTick - spacing;
        if (tick < market.minTick) tick = market.minTick;
        if (tick > lastValidTick) tick = lastValidTick;

        // Align to tick spacing.
        int256 offset = tick - market.minTick;
        tick = market.minTick + (offset / spacing) * spacing;
        return tick;
    }
    // slither-disable-end write-after-write
    // slither-disable-end divide-before-multiply
}
