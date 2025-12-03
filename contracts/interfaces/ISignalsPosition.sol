// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISignalsPosition {
    struct Position {
        uint256 marketId;
        int256 lowerTick;
        int256 upperTick;
        uint128 quantity;
        uint64 createdAt;
    }

    function mintPosition(
        address trader,
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external returns (uint256 positionId);

    function burn(uint256 positionId) external;

    function updateQuantity(uint256 positionId, uint128 newQuantity) external;

    function getPosition(uint256 positionId) external view returns (Position memory position);

    function exists(uint256 positionId) external view returns (bool);
}
