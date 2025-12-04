// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../interfaces/ISignalsCore.sol";
import "../errors/CLMSRErrors.sol";
import "../errors/ModuleErrors.sol";

/// @notice Delegate-only trade module (skeleton)
contract TradeModule is SignalsCoreStorage {
    address private immutable self;

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // --- External stubs ---
    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external onlyDelegated returns (uint256 positionId) {
        marketId;
        lowerTick;
        upperTick;
        quantity;
        maxCost;
        positionId = 0;
    }

    function increasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 maxCost
    ) external onlyDelegated {
        positionId;
        quantity;
        maxCost;
    }

    function decreasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 minProceeds
    ) external onlyDelegated {
        positionId;
        quantity;
        minProceeds;
    }

    function closePosition(
        uint256 positionId,
        uint256 minProceeds
    ) external onlyDelegated {
        positionId;
        minProceeds;
    }

    function claimPayout(uint256 positionId) external onlyDelegated {
        positionId;
    }

    // --- View stubs ---

    function calculateOpenCost(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external view onlyDelegated returns (uint256 cost) {
        marketId;
        lowerTick;
        upperTick;
        quantity;
        cost = 0;
    }

    function calculateIncreaseCost(
        uint256 positionId,
        uint128 quantity
    ) external view onlyDelegated returns (uint256 cost) {
        positionId;
        quantity;
        cost = 0;
    }

    function calculateDecreaseProceeds(
        uint256 positionId,
        uint128 quantity
    ) external view onlyDelegated returns (uint256 proceeds) {
        positionId;
        quantity;
        proceeds = 0;
    }

    function calculateCloseProceeds(
        uint256 positionId
    ) external view onlyDelegated returns (uint256 proceeds) {
        positionId;
        proceeds = 0;
    }

    function calculatePositionValue(
        uint256 positionId
    ) external view onlyDelegated returns (uint256 value) {
        positionId;
        value = 0;
    }

    // --- Shared validation helpers ---

    function _marketExists(uint256 marketId) internal view returns (bool) {
        return markets[marketId].numBins > 0;
    }

    /// @dev Loads a market and enforces active/time checks shared across trade entrypoints.
    function _loadAndValidateMarket(uint256 marketId)
        internal
        view
        returns (ISignalsCore.Market storage market)
    {
        market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (!market.isActive) revert CE.MarketNotActive();
        if (block.timestamp < market.startTimestamp) revert CE.MarketNotStarted();
        if (block.timestamp > market.endTimestamp) revert CE.MarketExpired();
    }

    function _validateTick(int256 tick, ISignalsCore.Market memory market) internal pure {
        if (tick < market.minTick || tick > market.maxTick) {
            revert CE.InvalidTick(tick, market.minTick, market.maxTick);
        }
        if ((tick - market.minTick) % market.tickSpacing != 0) {
            revert CE.InvalidTickSpacing(tick, market.tickSpacing);
        }
    }

    /// @dev Validates tick ordering/spacing; “no point betting” enforced via strict inequality.
    function _validateTickRange(
        int256 lowerTick,
        int256 upperTick,
        ISignalsCore.Market memory market
    ) internal pure {
        _validateTick(lowerTick, market);
        _validateTick(upperTick, market);
        if (lowerTick >= upperTick) {
            revert CE.InvalidTickRange(lowerTick, upperTick);
        }
        if ((upperTick - lowerTick) % market.tickSpacing != 0) {
            revert CE.InvalidTickRange(lowerTick, upperTick);
        }
    }
}
