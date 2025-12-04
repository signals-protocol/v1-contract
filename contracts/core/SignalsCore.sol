// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./storage/SignalsCoreStorage.sol";
import "../interfaces/ISignalsCore.sol";
import "../interfaces/ISignalsPosition.sol";

/// @title SignalsCore
/// @notice Upgradeable entry core that holds storage and delegates to modules
contract SignalsCore is
    Initializable,
    ISignalsCore,
    SignalsCoreStorage,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    address public tradeModule;
    address public lifecycleModule;
    address public riskModule;
    address public vaultModule;
    address public oracleModule;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Core initializer
    function initialize(
        address _paymentToken,
        address _positionContract,
        uint64 _settlementSubmitWindow,
        uint64 _settlementFinalizeDeadline
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        paymentToken = IERC20(_paymentToken);
        positionContract = ISignalsPosition(_positionContract);
        settlementSubmitWindow = _settlementSubmitWindow;
        settlementFinalizeDeadline = _settlementFinalizeDeadline;
    }

    /// @notice Set module addresses
    function setModules(
        address _tradeModule,
        address _lifecycleModule,
        address _riskModule,
        address _vaultModule,
        address _oracleModule
    ) external onlyOwner {
        tradeModule = _tradeModule;
        lifecycleModule = _lifecycleModule;
        riskModule = _riskModule;
        vaultModule = _vaultModule;
        oracleModule = _oracleModule;
    }

    // --- External stubs: delegate to modules ---

    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external override whenNotPaused nonReentrant returns (uint256 positionId) {
        bytes memory ret = _delegate(tradeModule, abi.encodeWithSignature(
            "openPosition(uint256,int256,int256,uint128,uint256)",
            marketId,
            lowerTick,
            upperTick,
            quantity,
            maxCost
        ));
        if (ret.length > 0) positionId = abi.decode(ret, (uint256));
    }

    function increasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 maxCost
    ) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature(
            "increasePosition(uint256,uint128,uint256)",
            positionId,
            quantity,
            maxCost
        ));
    }

    function decreasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 minProceeds
    ) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature(
            "decreasePosition(uint256,uint128,uint256)",
            positionId,
            quantity,
            minProceeds
        ));
    }

    function closePosition(
        uint256 positionId,
        uint256 minProceeds
    ) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature(
            "closePosition(uint256,uint256)",
            positionId,
            minProceeds
        ));
    }

    function claimPayout(uint256 positionId) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature("claimPayout(uint256)", positionId));
    }

    // ---- View stubs ----

    function calculateOpenCost(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external view override returns (uint256 cost) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateOpenCost(uint256,int256,int256,uint128)",
            marketId,
            lowerTick,
            upperTick,
            quantity
        ));
        if (ret.length > 0) cost = abi.decode(ret, (uint256));
    }

    function calculateIncreaseCost(
        uint256 positionId,
        uint128 quantity
    ) external view override returns (uint256 cost) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateIncreaseCost(uint256,uint128)",
            positionId,
            quantity
        ));
        if (ret.length > 0) cost = abi.decode(ret, (uint256));
    }

    function calculateDecreaseProceeds(
        uint256 positionId,
        uint128 quantity
    ) external view override returns (uint256 proceeds) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateDecreaseProceeds(uint256,uint128)",
            positionId,
            quantity
        ));
        if (ret.length > 0) proceeds = abi.decode(ret, (uint256));
    }

    function calculateCloseProceeds(
        uint256 positionId
    ) external view override returns (uint256 proceeds) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateCloseProceeds(uint256)",
            positionId
        ));
        if (ret.length > 0) proceeds = abi.decode(ret, (uint256));
    }

    function calculatePositionValue(
        uint256 positionId
    ) external view override returns (uint256 value) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculatePositionValue(uint256)",
            positionId
        ));
        if (ret.length > 0) value = abi.decode(ret, (uint256));
    }

    /// @notice Trigger settlement snapshot chunks after market settlement (owner only).
    function requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx)
        external
        override
        onlyOwner
        whenNotPaused
        returns (uint32 emitted)
    {
        bytes memory ret = _delegate(lifecycleModule, abi.encodeWithSignature(
            "requestSettlementChunks(uint256,uint32)",
            marketId,
            maxChunksPerTx
        ));
        if (ret.length > 0) emitted = abi.decode(ret, (uint32));
    }

    // --- Internal: delegate helpers ---

    /// @dev Delegate to a module preserving context, bubble up revert
    function _delegate(address module, bytes memory callData) internal returns (bytes memory) {
        require(module != address(0), "ModuleNotSet");
        (bool success, bytes memory ret) = module.delegatecall(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    /// @dev Delegate to a module for view paths via staticcall; bubble up reverts.
    function _delegateView(address module, bytes memory callData) internal view returns (bytes memory) {
        require(module != address(0), "ModuleNotSet");
        (bool success, bytes memory ret) = module.staticcall(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
