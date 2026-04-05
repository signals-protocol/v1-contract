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
    struct DeployConfig {
        address coreImpl;
        address positionImpl;
        address lpShareImpl;
        bytes32 coreSalt;
        bytes32 positionSalt;
        bytes32 lpShareSalt;
        address expectedCoreProxy;
        address expectedPositionProxy;
        address expectedLpShareProxy;
        SignalsCore.InitParams coreParams;
        string lpShareName;
        string lpShareSymbol;
    }

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
        SignalsCore.InitParams memory coreParams,
        string memory lpShareName,
        string memory lpShareSymbol
    ) external onlyDeployer returns (address coreProxy, address positionProxy, address lpShareProxy) {
        DeployConfig memory config;
        config.coreImpl = coreImpl;
        config.positionImpl = positionImpl;
        config.lpShareImpl = lpShareImpl;
        config.coreSalt = coreSalt;
        config.positionSalt = positionSalt;
        config.lpShareSalt = lpShareSalt;
        config.expectedCoreProxy = expectedCoreProxy;
        config.expectedPositionProxy = expectedPositionProxy;
        config.expectedLpShareProxy = expectedLpShareProxy;
        config.coreParams = coreParams;
        config.lpShareName = lpShareName;
        config.lpShareSymbol = lpShareSymbol;

        return _deployAllDeterministic(config);
    }

    function _deployAllDeterministic(DeployConfig memory config) internal returns (address, address, address) {
        if (executed) revert DeploymentAlreadyExecuted();

        _validateInputs(config);

        address coreProxy = _deployExpectedProxy(config.coreImpl, config.coreSalt, config.expectedCoreProxy);
        address positionProxy = _deployExpectedProxy(
            config.positionImpl,
            config.positionSalt,
            config.expectedPositionProxy
        );
        address lpShareProxy = _deployExpectedProxy(
            config.lpShareImpl,
            config.lpShareSalt,
            config.expectedLpShareProxy
        );

        _verifyInitTargets(config.coreParams, positionProxy, lpShareProxy);
        _initializeProxies(config, coreProxy, positionProxy, lpShareProxy);
        _verifyWiring(config, coreProxy, positionProxy, lpShareProxy);

        executed = true;

        return (coreProxy, positionProxy, lpShareProxy);
    }

    function _validateInputs(DeployConfig memory config) internal view {
        _requireAddress(config.coreImpl);
        _requireAddress(config.positionImpl);
        _requireAddress(config.lpShareImpl);
        _requireAddress(config.expectedCoreProxy);
        _requireAddress(config.expectedPositionProxy);
        _requireAddress(config.expectedLpShareProxy);
        _requireContract(config.coreImpl);
        _requireContract(config.positionImpl);
        _requireContract(config.lpShareImpl);
    }

    function _deployExpectedProxy(address impl, bytes32 salt, address expectedProxy) internal returns (address proxy) {
        bytes memory initCode = _proxyInitCode(impl);
        address predictedProxy = Create2.computeAddress(salt, keccak256(initCode), address(this));

        if (predictedProxy != expectedProxy) {
            revert Create2AddressMismatch(expectedProxy, predictedProxy);
        }

        proxy = Create2.deploy(0, salt, initCode);
    }

    function _verifyInitTargets(
        SignalsCore.InitParams memory coreParams,
        address positionProxy,
        address lpShareProxy
    ) internal pure {
        if (coreParams.positionContract != positionProxy) {
            revert Create2AddressMismatch(coreParams.positionContract, positionProxy);
        }
        if (coreParams.lpShareToken != lpShareProxy) {
            revert Create2AddressMismatch(coreParams.lpShareToken, lpShareProxy);
        }
    }

    function _initializeProxies(
        DeployConfig memory config,
        address coreProxy,
        address positionProxy,
        address lpShareProxy
    ) internal {
        SignalsCore(coreProxy).initialize(config.coreParams);
        SignalsPosition(positionProxy).initialize(coreProxy, config.coreParams.ownerSafe);
        SignalsLPShare(lpShareProxy).initialize(
            coreProxy,
            config.coreParams.paymentToken,
            config.lpShareName,
            config.lpShareSymbol,
            config.coreParams.ownerSafe
        );
    }

    function _verifyWiring(
        DeployConfig memory config,
        address coreProxy,
        address positionProxy,
        address lpShareProxy
    ) internal view {
        if (SignalsCore(coreProxy).owner() != config.coreParams.ownerSafe) {
            revert Create2AddressMismatch(config.coreParams.ownerSafe, SignalsCore(coreProxy).owner());
        }
        if (SignalsPosition(positionProxy).owner() != config.coreParams.ownerSafe) {
            revert Create2AddressMismatch(config.coreParams.ownerSafe, SignalsPosition(positionProxy).owner());
        }
        if (SignalsLPShare(lpShareProxy).owner() != config.coreParams.ownerSafe) {
            revert Create2AddressMismatch(config.coreParams.ownerSafe, SignalsLPShare(lpShareProxy).owner());
        }

        address paymentToken = address(SignalsCore(coreProxy).paymentToken());
        if (paymentToken != config.coreParams.paymentToken) {
            revert Create2AddressMismatch(config.coreParams.paymentToken, paymentToken);
        }

        address positionContract = address(SignalsCore(coreProxy).positionContract());
        if (positionContract != positionProxy) {
            revert Create2AddressMismatch(positionProxy, positionContract);
        }

        if (SignalsCore(coreProxy).lpShareToken() != lpShareProxy) {
            revert Create2AddressMismatch(lpShareProxy, SignalsCore(coreProxy).lpShareToken());
        }
        if (SignalsCore(coreProxy).tradeModule() != config.coreParams.tradeModule) {
            revert Create2AddressMismatch(config.coreParams.tradeModule, SignalsCore(coreProxy).tradeModule());
        }
        if (SignalsCore(coreProxy).lifecycleModule() != config.coreParams.lifecycleModule) {
            revert Create2AddressMismatch(config.coreParams.lifecycleModule, SignalsCore(coreProxy).lifecycleModule());
        }
        if (SignalsCore(coreProxy).riskModule() != config.coreParams.riskModule) {
            revert Create2AddressMismatch(config.coreParams.riskModule, SignalsCore(coreProxy).riskModule());
        }
        if (SignalsCore(coreProxy).vaultModule() != config.coreParams.vaultModule) {
            revert Create2AddressMismatch(config.coreParams.vaultModule, SignalsCore(coreProxy).vaultModule());
        }
        if (SignalsCore(coreProxy).oracleModule() != config.coreParams.oracleModule) {
            revert Create2AddressMismatch(config.coreParams.oracleModule, SignalsCore(coreProxy).oracleModule());
        }
        if (SignalsPosition(positionProxy).core() != coreProxy) {
            revert Create2AddressMismatch(coreProxy, SignalsPosition(positionProxy).core());
        }
        if (SignalsLPShare(lpShareProxy).core() != coreProxy) {
            revert Create2AddressMismatch(coreProxy, SignalsLPShare(lpShareProxy).core());
        }
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
