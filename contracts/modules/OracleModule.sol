// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../errors/ModuleErrors.sol";

/// @notice Delegate-only oracle module (skeleton)
contract OracleModule is SignalsCoreStorage {
    address private immutable self;

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    function setOracleConfig(
        uint256 /*marketId*/,
        bytes calldata /*configData*/
    ) external onlyDelegated {
        // implementation to be ported in Phase 3-4
    }

    function getSettlementPrice(uint256 /*marketId*/, uint256 /*timestamp*/)
        external
        view
        onlyDelegated
        returns (int256 price, uint64 priceTimestamp)
    {
        price;
        priceTimestamp;
    }
}
