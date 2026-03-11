// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISignalsPosition.sol";

abstract contract SignalsPositionStorage {
    address public core;
    uint256 internal _nextId;
    mapping(uint256 => ISignalsPosition.Position) internal _positions;
    // @deprecated No longer written to. Kept for storage layout compatibility (UUPS proxy).
    mapping(uint256 => uint256[]) internal _marketTokenList;
    // @deprecated No longer written to. Kept for storage layout compatibility (UUPS proxy).
    mapping(uint256 => uint256) internal _positionMarketIndex;
    // @deprecated No longer written to. Kept for storage layout compatibility (UUPS proxy).
    mapping(address => uint256[]) internal _ownerTokenList;
    // @deprecated No longer written to. Kept for storage layout compatibility (UUPS proxy).
    mapping(uint256 => uint256) internal _positionOwnerIndex;

    // Reserve ample slots for future upgrades; do not change after first deployment.
    uint256[48] internal __gap;
}
