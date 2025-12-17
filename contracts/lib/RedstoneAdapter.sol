// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@redstone-finance/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";

/// @title RedstoneAdapter
/// @notice Standalone Redstone consumer to avoid stack depth issues in OracleModule
/// @dev Inherits PrimaryProdDataServiceConsumerBase and exposes parsing functions
contract RedstoneAdapter is PrimaryProdDataServiceConsumerBase {
    /// @notice Extract price and timestamp from Redstone payload in calldata
    /// @param feedId The data feed ID (e.g., bytes32("BTC"))
    /// @return price The extracted price value
    /// @return timestampMs The extracted timestamp in milliseconds
    function extractPriceAndTimestamp(bytes32 feedId) 
        external 
        view 
        returns (uint256 price, uint256 timestampMs) 
    {
        price = getOracleNumericValueFromTxMsg(feedId);
        timestampMs = extractTimestampsAndAssertAllAreEqual();
    }
}

