// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/ISignalsPosition.sol";

abstract contract SignalsPositionStorage {
    address public core;
    uint256 internal _nextId;
    mapping(uint256 => ISignalsPosition.Position) internal _positions;
    mapping(uint256 => uint256[]) internal _marketTokenList;
    mapping(uint256 => uint256) internal _positionMarketIndex;

    // Reserve ample slots for future upgrades; do not change after first deployment.
    uint256[50] internal __gap;
}
