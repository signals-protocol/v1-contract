// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../errors/SignalsErrors.sol";
import "../core/SignalsCore.sol";
import "../position/SignalsPosition.sol";
import "../tokens/SignalsLPShare.sol";

/// @notice Deterministic one-shot deployer for Core/Position/LPShare proxies.
contract SignalsDeployer is SignalsErrors {
    address public immutable deployerEOA;
    bool public executed;

    modifier onlyDeployer() {
        if (msg.sender != deployerEOA) revert UnauthorizedCaller(msg.sender);
        _;
    }

    constructor(address deployerEOA_) {
        if (deployerEOA_ == address(0)) revert ZeroAddress();
        deployerEOA = deployerEOA_;
    }

    function deployAllDeterministic(
        address coreImpl,
        address positionImpl,
        address lpShareImpl,
        bytes32 coreSalt,
        bytes32 positionSalt,
        bytes32 lpShareSalt,
        address expectedCoreProxy,
        address expectedPositionProxy,
        address expectedLpShareProxy,
        SignalsCore.InitParams calldata coreParams,
        string calldata lpShareName,
        string calldata lpShareSymbol
    ) external onlyDeployer returns (address coreProxy, address positionProxy, address lpShareProxy) {
        if (executed) revert DeploymentAlreadyExecuted();

        _requireAddress(coreImpl);
        _requireAddress(positionImpl);
        _requireAddress(lpShareImpl);
        _requireAddress(expectedCoreProxy);
        _requireAddress(expectedPositionProxy);
        _requireAddress(expectedLpShareProxy);
        _requireContract(coreImpl);
        _requireContract(positionImpl);
        _requireContract(lpShareImpl);

        bytes memory coreInitCode = _proxyInitCode(coreImpl);
        bytes memory positionInitCode = _proxyInitCode(positionImpl);
        bytes memory lpShareInitCode = _proxyInitCode(lpShareImpl);

        address predictedCore = Create2.computeAddress(coreSalt, keccak256(coreInitCode), address(this));
        address predictedPosition = Create2.computeAddress(positionSalt, keccak256(positionInitCode), address(this));
        address predictedLpShare = Create2.computeAddress(lpShareSalt, keccak256(lpShareInitCode), address(this));

        if (predictedCore != expectedCoreProxy) {
            revert Create2AddressMismatch(expectedCoreProxy, predictedCore);
        }
        if (predictedPosition != expectedPositionProxy) {
            revert Create2AddressMismatch(expectedPositionProxy, predictedPosition);
        }
        if (predictedLpShare != expectedLpShareProxy) {
            revert Create2AddressMismatch(expectedLpShareProxy, predictedLpShare);
        }

        coreProxy = Create2.deploy(0, coreSalt, coreInitCode);
        positionProxy = Create2.deploy(0, positionSalt, positionInitCode);
        lpShareProxy = Create2.deploy(0, lpShareSalt, lpShareInitCode);

        if (coreParams.positionContract != positionProxy) {
            revert Create2AddressMismatch(coreParams.positionContract, positionProxy);
        }
        if (coreParams.lpShareToken != lpShareProxy) {
            revert Create2AddressMismatch(coreParams.lpShareToken, lpShareProxy);
        }

        SignalsCore(coreProxy).initialize(coreParams);
        SignalsPosition(positionProxy).initialize(coreProxy, coreParams.ownerSafe);
        SignalsLPShare(lpShareProxy).initialize(
            coreProxy,
            coreParams.paymentToken,
            lpShareName,
            lpShareSymbol,
            coreParams.ownerSafe
        );

        if (SignalsCore(coreProxy).owner() != coreParams.ownerSafe) {
            revert Create2AddressMismatch(coreParams.ownerSafe, SignalsCore(coreProxy).owner());
        }
        if (SignalsPosition(positionProxy).owner() != coreParams.ownerSafe) {
            revert Create2AddressMismatch(coreParams.ownerSafe, SignalsPosition(positionProxy).owner());
        }
        if (SignalsLPShare(lpShareProxy).owner() != coreParams.ownerSafe) {
            revert Create2AddressMismatch(coreParams.ownerSafe, SignalsLPShare(lpShareProxy).owner());
        }
        address paymentToken = address(SignalsCore(coreProxy).paymentToken());
        if (paymentToken != coreParams.paymentToken) {
            revert Create2AddressMismatch(coreParams.paymentToken, paymentToken);
        }
        address positionContract = address(SignalsCore(coreProxy).positionContract());
        if (positionContract != positionProxy) {
            revert Create2AddressMismatch(positionProxy, positionContract);
        }
        if (SignalsCore(coreProxy).lpShareToken() != lpShareProxy) {
            revert Create2AddressMismatch(lpShareProxy, SignalsCore(coreProxy).lpShareToken());
        }
        if (SignalsCore(coreProxy).tradeModule() != coreParams.tradeModule) {
            revert Create2AddressMismatch(coreParams.tradeModule, SignalsCore(coreProxy).tradeModule());
        }
        if (SignalsCore(coreProxy).lifecycleModule() != coreParams.lifecycleModule) {
            revert Create2AddressMismatch(coreParams.lifecycleModule, SignalsCore(coreProxy).lifecycleModule());
        }
        if (SignalsCore(coreProxy).riskModule() != coreParams.riskModule) {
            revert Create2AddressMismatch(coreParams.riskModule, SignalsCore(coreProxy).riskModule());
        }
        if (SignalsCore(coreProxy).vaultModule() != coreParams.vaultModule) {
            revert Create2AddressMismatch(coreParams.vaultModule, SignalsCore(coreProxy).vaultModule());
        }
        if (SignalsCore(coreProxy).oracleModule() != coreParams.oracleModule) {
            revert Create2AddressMismatch(coreParams.oracleModule, SignalsCore(coreProxy).oracleModule());
        }
        if (SignalsPosition(positionProxy).core() != coreProxy) {
            revert Create2AddressMismatch(coreProxy, SignalsPosition(positionProxy).core());
        }
        if (SignalsLPShare(lpShareProxy).core() != coreProxy) {
            revert Create2AddressMismatch(coreProxy, SignalsLPShare(lpShareProxy).core());
        }

        executed = true;
    }

    function _proxyInitCode(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, ""));
    }

    function _requireAddress(address value) internal pure {
        if (value == address(0)) revert ZeroAddress();
    }

    function _requireContract(address value) internal view {
        if (value.code.length == 0) revert ModuleNotSet();
    }
}
