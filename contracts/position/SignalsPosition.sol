// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../errors/SignalsErrors.sol";
import "../interfaces/ISignalsPosition.sol";
import "./SignalsPositionStorage.sol";

/// @notice Upgradeable ERC721 position token with core-only mint/burn/update and indexing helpers.
contract SignalsPosition is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    SignalsErrors,
    SignalsPositionStorage
{
    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        uint256 indexed marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    );

    event PositionBurned(uint256 indexed positionId, address indexed owner);

    event PositionUpdated(uint256 indexed positionId, uint128 oldQuantity, uint128 newQuantity);

    modifier onlyCore() {
        if (msg.sender != core) revert SignalsErrors.UnauthorizedCaller(msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core) external initializer {
        if (_core == address(0)) revert SignalsErrors.ZeroAddress();
        __ERC721_init("Signals Position", "SIGP");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        core = _core;
        _nextId = 1;
    }

    function setCore(address _core) external onlyOwner {
        if (_core == address(0)) revert SignalsErrors.ZeroAddress();
        core = _core;
    }

    // --- Core-only position lifecycle ---

    function mintPosition(
        address to,
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external onlyCore returns (uint256 positionId) {
        if (to == address(0)) revert SignalsErrors.ZeroAddress();
        if (quantity == 0) revert SignalsErrors.InvalidQuantity(quantity);

        positionId = _nextId++;

        _positions[positionId] = ISignalsPosition.Position({
            marketId: marketId,
            lowerTick: lowerTick,
            upperTick: upperTick,
            quantity: quantity,
            createdAt: uint64(block.timestamp)
        });

        _safeMint(to, positionId);
        _addPositionToMarket(marketId, positionId);

        emit PositionMinted(positionId, to, marketId, lowerTick, upperTick, quantity);
    }

    function burn(uint256 positionId) external onlyCore {
        if (!_exists(positionId)) revert SignalsErrors.PositionNotFound(positionId);
        address owner = ownerOf(positionId);
        uint256 marketId = _positions[positionId].marketId;

        _burn(positionId);
        _removePositionFromMarket(marketId, positionId);
        delete _positions[positionId];

        emit PositionBurned(positionId, owner);
    }

    function updateQuantity(uint256 positionId, uint128 newQuantity) external onlyCore {
        if (!_exists(positionId)) revert SignalsErrors.PositionNotFound(positionId);
        if (newQuantity == 0) revert SignalsErrors.InvalidQuantity(newQuantity);
        uint128 oldQty = _positions[positionId].quantity;
        _positions[positionId].quantity = newQuantity;
        emit PositionUpdated(positionId, oldQty, newQuantity);
    }

    // --- Views ---

    function getPosition(uint256 positionId) external view returns (ISignalsPosition.Position memory position) {
        if (!_exists(positionId)) revert SignalsErrors.PositionNotFound(positionId);
        return _positions[positionId];
    }

    function exists(uint256 positionId) external view returns (bool) {
        return _exists(positionId);
    }

    function getPositionsByOwner(address owner) external view returns (uint256[] memory positions) {
        positions = _ownerTokenList[owner];
    }

    function getMarketTokenLength(uint256 marketId) external view returns (uint256 length) {
        return _marketTokenList[marketId].length;
    }

    function getMarketTokenAt(uint256 marketId, uint256 index) external view returns (uint256 tokenId) {
        return _marketTokenList[marketId][index];
    }

    function getMarketPositions(uint256 marketId) external view returns (uint256[] memory tokenIds) {
        tokenIds = _marketTokenList[marketId];
    }

    function getUserPositionsInMarket(address owner, uint256 marketId) external view returns (uint256[] memory tokenIds) {
        uint256[] storage list = _marketTokenList[marketId];
        uint256 count;
        for (uint256 i = 0; i < list.length; i++) {
            uint256 tokenId = list[i];
            if (tokenId != 0 && _ownerOf(tokenId) == owner) {
                count++;
            }
        }
        tokenIds = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < list.length; i++) {
            uint256 tokenId = list[i];
            if (tokenId != 0 && _ownerOf(tokenId) == owner) {
                tokenIds[idx++] = tokenId;
            }
        }
    }

    function nextId() external view returns (uint256) {
        return _nextId;
    }

    // --- Internal helpers ---

    function _addPositionToMarket(uint256 marketId, uint256 positionId) internal {
        _marketTokenList[marketId].push(positionId);
        _positionMarketIndex[positionId] = _marketTokenList[marketId].length; // 1-based
    }

    function _removePositionFromMarket(uint256 marketId, uint256 positionId) internal {
        uint256 idx = _positionMarketIndex[positionId];
        if (idx == 0) return;
        uint256 arrIndex = idx - 1;
        if (arrIndex < _marketTokenList[marketId].length) {
            _marketTokenList[marketId][arrIndex] = 0;
        }
        delete _positionMarketIndex[positionId];
    }

    function _addPositionToOwner(address owner, uint256 positionId) internal {
        _ownerTokenList[owner].push(positionId);
        _positionOwnerIndex[positionId] = _ownerTokenList[owner].length; // 1-based
    }

    function _removePositionFromOwner(address owner, uint256 positionId) internal {
        uint256 idx = _positionOwnerIndex[positionId];
        if (idx == 0) return;
        uint256 arrIndex = idx - 1;
        uint256[] storage list = _ownerTokenList[owner];
        if (arrIndex < list.length) {
            uint256 last = list[list.length - 1];
            list[arrIndex] = last;
            list.pop();
            if (last != positionId) {
                _positionOwnerIndex[last] = arrIndex + 1;
            }
        }
        delete _positionOwnerIndex[positionId];
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0)) {
            _removePositionFromOwner(from, tokenId);
        }
        if (to != address(0)) {
            _addPositionToOwner(to, tokenId);
        }
        return from;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
