// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../modules/TradeModule.sol";

/// @notice Harness to expose TradeModule validation helpers for testing.
contract TradeModuleHarness is TradeModule {
    /// @notice Set a market struct directly for testing.
    function setMarket(uint256 marketId, ISignalsCore.Market calldata market) external {
        markets[marketId] = market;
    }

    /// @notice Expose market existence check.
    function exposedMarketExists(uint256 marketId) external view returns (bool) {
        return _marketExists(marketId);
    }

    /// @notice Expose shared market validation (active + time).
    function exposedLoadAndValidateMarket(uint256 marketId)
        external
        view
        returns (ISignalsCore.Market memory)
    {
        ISignalsCore.Market storage market = _loadAndValidateMarket(marketId);
        return market;
    }

    /// @notice Expose tick range validation.
    function exposedValidateTickRange(
        int256 lowerTick,
        int256 upperTick,
        uint256 marketId
    ) external view {
        ISignalsCore.Market memory market = markets[marketId];
        _validateTickRange(lowerTick, upperTick, market);
    }
}
