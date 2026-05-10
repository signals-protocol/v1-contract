// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../errors/SignalsErrors.sol";
import "../interfaces/ISignalsPosition.sol";
import "./SignalsPositionStorage.sol";

/// @notice Upgradeable ERC721 position token with core-only mint/burn/update.
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

    function initialize(address _core, address _ownerSafe) external initializer {
        if (_core == address(0)) revert SignalsErrors.ZeroAddress();
        if (_ownerSafe == address(0)) revert SignalsErrors.ZeroAddress();
        if (_core.code.length == 0) revert SignalsErrors.ModuleNotSet();
        __ERC721_init("Signals Position", "SIGP");
        __Ownable_init(_ownerSafe);
        __UUPSUpgradeable_init();
        core = _core;
        _nextId = 1;
    }

    // --- Core-only position lifecycle ---

    function mintPosition(address to, uint256 marketId, int256 lowerTick, int256 upperTick, uint128 quantity)
        external
        onlyCore
        returns (uint256 positionId)
    {
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

        emit PositionMinted(positionId, to, marketId, lowerTick, upperTick, quantity);
    }

    function burn(uint256 positionId) external onlyCore {
        if (!_exists(positionId)) revert SignalsErrors.PositionNotFound(positionId);
        address positionOwner = ownerOf(positionId);

        _burn(positionId);
        delete _positions[positionId];

        emit PositionBurned(positionId, positionOwner);
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

    function nextId() external view returns (uint256) {
        return _nextId;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
