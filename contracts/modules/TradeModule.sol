// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../interfaces/ISignalsCore.sol";
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
}
