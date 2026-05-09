// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISignalsPosition.sol";

abstract contract SignalsPositionStorage {
    address public core;
    uint256 internal _nextId;
    mapping(uint256 => ISignalsPosition.Position) internal _positions;
    /// @custom:oz-renamed-from _marketTokenList
    mapping(uint256 => uint256[]) internal __deprecated_slot_3;
    /// @custom:oz-renamed-from _positionMarketIndex
    mapping(uint256 => uint256) internal __deprecated_slot_4;
    /// @custom:oz-renamed-from _ownerTokenList
    mapping(address => uint256[]) internal __deprecated_slot_5;
    /// @custom:oz-renamed-from _positionOwnerIndex
    mapping(uint256 => uint256) internal __deprecated_slot_6;

    // Reserve ample slots for future upgrades; do not change after first deployment.
    uint256[48] internal __gap;
}
