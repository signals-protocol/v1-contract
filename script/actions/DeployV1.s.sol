// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {Constants} from "../base/Constants.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {SignalsPosition} from "../../contracts/position/SignalsPosition.sol";
import {SignalsLPShare} from "../../contracts/tokens/SignalsLPShare.sol";
import {SignalsDeployer} from "../../contracts/deploy/SignalsDeployer.sol";
import {SignalsCreate2Factory} from "../../contracts/deploy/SignalsCreate2Factory.sol";
import {NullFeePolicy} from "../../contracts/fees/NullFeePolicy.sol";
import {
    PercentFeePolicy10bps,
    PercentFeePolicy50bps,
    PercentFeePolicy100bps,
    PercentFeePolicy200bps
} from "../../contracts/fees/PercentFeePolicies.sol";
import {TradeModule} from "../../contracts/modules/TradeModule.sol";
import {MarketLifecycleModule} from "../../contracts/modules/MarketLifecycleModule.sol";
import {OracleModule} from "../../contracts/modules/OracleModule.sol";
import {RiskModule} from "../../contracts/modules/RiskModule.sol";
import {LPVaultModule} from "../../contracts/modules/LPVaultModule.sol";
import {SignalsUSDToken} from "../../contracts/testonly/SignalsUSDToken.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {console} from "forge-std/console.sol";

/// @title DeployV1 — Full V1 deployment: fee policies, modules, impls, CREATE2 proxies
/// @notice Reads deploy config from script/config/deploy-{env}.json
/// @dev Env vars: PRIVATE_KEY, ENV, OWNER_SAFE (optional), PAYMENT_TOKEN_ADDRESS (optional),
///      OPERATORS_JSON (optional, e.g. '["0x..."]')
contract DeployV1 is BaseScript {
    struct DeployConfig {
        uint256 submitWindowSec;
        uint256 pendingOpsWindowSec;
        string feedId;
        uint256 feedDecimals;
        uint256 maxSampleDistanceSec;
        uint256 futureToleranceSec;
        uint256 lambdaWad;
        uint256 kDrawdownWad;
        bool enforceAlpha;
        uint256 rhoBSWad;
        uint256 phiLPWad;
        uint256 phiBSWad;
        uint256 phiTRWad;
        uint256 withdrawalLagBatches;
        string lpShareName;
        string lpShareSymbol;
        string release;
        string vanityPrefix;
        uint256 maxNonce;
    }

    function run() external {
        _enforceChainId();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("[deploy] deployer=%s env=%s", deployer, envName);

        DeployConfig memory cfg = _loadDeployConfig();

        // Resolve owner safe
        address ownerSafe = vm.envOr("OWNER_SAFE", deployer);

        // Resolve payment token
        address paymentAddr = _resolvePaymentToken(deployer, deployerKey);

        // Resolve operators
        address[] memory operators = _resolveOperators(deployer);

        vm.startBroadcast(deployerKey);

        // ── Fee policies ────────────────────────────────────────────────
        NullFeePolicy nullFee = new NullFeePolicy();
        PercentFeePolicy10bps fee10 = new PercentFeePolicy10bps();
        PercentFeePolicy50bps fee50 = new PercentFeePolicy50bps();
        PercentFeePolicy100bps fee100 = new PercentFeePolicy100bps();
        PercentFeePolicy200bps fee200 = new PercentFeePolicy200bps();

        // ── Modules ─────────────────────────────────────────────────────
        TradeModule tradeModule = new TradeModule();
        MarketLifecycleModule lifecycleModule = new MarketLifecycleModule();
        OracleModule oracleModule = new OracleModule();
        RiskModule riskModule = new RiskModule();
        LPVaultModule vaultModule = new LPVaultModule();

        // ── Implementations (with reuse) ────────────────────────────────
        address coreImplAddr = _resolveImpl("SignalsCoreImplementation");
        if (coreImplAddr == address(0)) {
            SignalsCore impl = new SignalsCore();
            coreImplAddr = address(impl);
        }

        address positionImplAddr = _resolveImpl("SignalsPositionImplementation");
        if (positionImplAddr == address(0)) {
            SignalsPosition impl = new SignalsPosition();
            positionImplAddr = address(impl);
        }

        address lpShareImplAddr = _resolveImpl("SignalsLPShareImplementation");
        if (lpShareImplAddr == address(0)) {
            SignalsLPShare impl = new SignalsLPShare();
            lpShareImplAddr = address(impl);
        }

        // ── Create2Factory (reuse or deploy) ────────────────────────────
        address factoryAddr = _resolveCreate2Factory(deployer);

        // Verify factory deployer
        SignalsCreate2Factory factory = SignalsCreate2Factory(factoryAddr);
        require(factory.allowedDeployer() == deployer, "Create2Factory allowedDeployer mismatch");

        // ── CREATE2 address prediction ──────────────────────────────────
        bytes memory deployerInitCode = abi.encodePacked(type(SignalsDeployer).creationCode, abi.encode(deployer));
        bytes32 deployerInitHash = keccak256(deployerInitCode);
        string memory deployerBase = _buildBase("DEPLOYER", cfg.release);
        bytes32 deployerSalt = _buildSalt(deployerBase, 0);
        address deployerAddr = Create2.computeAddress(deployerSalt, deployerInitHash, factoryAddr);

        // Proxy initcode hashes
        bytes32 coreInitHash = _proxyInitCodeHash(coreImplAddr);
        bytes32 positionInitHash = _proxyInitCodeHash(positionImplAddr);
        bytes32 lpShareInitHash = _proxyInitCodeHash(lpShareImplAddr);

        // Vanity search for core proxy
        string memory coreBase = _buildBase("CORE_PROXY", cfg.release);
        bytes32 coreSalt;
        address coreAddr;
        bytes memory vanityBytes = bytes(cfg.vanityPrefix);
        for (uint256 nonce = 0; nonce <= cfg.maxNonce; nonce++) {
            bytes32 salt = _buildSalt(coreBase, nonce);
            address predicted = Create2.computeAddress(salt, coreInitHash, deployerAddr);
            if (_matchesPrefix(predicted, vanityBytes)) {
                coreSalt = salt;
                coreAddr = predicted;
                break;
            }
        }
        require(coreAddr != address(0), "Core vanity not found");

        // Position & LPShare (nonce=0)
        bytes32 positionSalt = _buildSalt(_buildBase("POSITION_PROXY", cfg.release), 0);
        bytes32 lpShareSalt = _buildSalt(_buildBase("LPSHARE_PROXY", cfg.release), 0);
        address positionAddr = Create2.computeAddress(positionSalt, positionInitHash, deployerAddr);
        address lpShareAddr = Create2.computeAddress(lpShareSalt, lpShareInitHash, deployerAddr);

        // ── Deploy SignalsDeployer via factory ───────────────────────────
        if (deployerAddr.code.length == 0) {
            factory.deploy(deployerSalt, deployerInitCode);
        }
        require(deployerAddr.code.length > 0, "SignalsDeployer not deployed");

        // ── Build InitParams ────────────────────────────────────────────
        uint256 claimDelay = cfg.submitWindowSec + cfg.pendingOpsWindowSec;

        SignalsCore.InitParams memory params = SignalsCore.InitParams({
            paymentToken: paymentAddr,
            positionContract: positionAddr,
            lpShareToken: lpShareAddr,
            tradeModule: address(tradeModule),
            lifecycleModule: address(lifecycleModule),
            riskModule: address(riskModule),
            vaultModule: address(vaultModule),
            oracleModule: address(oracleModule),
            ownerSafe: ownerSafe,
            settlementSubmitWindow: uint64(cfg.submitWindowSec),
            pendingOpsWindow: uint64(cfg.pendingOpsWindowSec),
            claimDelaySeconds: uint64(claimDelay),
            redstoneFeedId: _toBytes32(cfg.feedId),
            redstoneFeedDecimals: uint8(cfg.feedDecimals),
            maxSampleDistance: uint64(cfg.maxSampleDistanceSec),
            futureTolerance: uint64(cfg.futureToleranceSec),
            lambda: cfg.lambdaWad,
            kDrawdown: cfg.kDrawdownWad,
            enforceAlpha: cfg.enforceAlpha,
            rhoBS: cfg.rhoBSWad,
            phiLP: cfg.phiLPWad,
            phiBS: cfg.phiBSWad,
            phiTR: cfg.phiTRWad,
            withdrawalLagBatches: uint64(cfg.withdrawalLagBatches),
            operatorAllowlist: operators
        });

        // ── Deploy all deterministic ────────────────────────────────────
        SignalsDeployer sigDeployer = SignalsDeployer(deployerAddr);
        sigDeployer.deployAllDeterministic(
            coreImplAddr,
            positionImplAddr,
            lpShareImplAddr,
            coreSalt,
            positionSalt,
            lpShareSalt,
            coreAddr,
            positionAddr,
            lpShareAddr,
            params,
            cfg.lpShareName,
            cfg.lpShareSymbol
        );

        vm.stopBroadcast();

        console.log("[deploy] coreProxy=%s", coreAddr);
        console.log("[deploy] positionProxy=%s", positionAddr);
        console.log("[deploy] lpShareProxy=%s", lpShareAddr);

        // ── Write output ────────────────────────────────────────────────
        _writeDeployOutput(
            deployer,
            factoryAddr,
            deployerAddr,
            coreAddr,
            positionAddr,
            lpShareAddr,
            coreImplAddr,
            positionImplAddr,
            lpShareImplAddr,
            address(tradeModule),
            address(lifecycleModule),
            address(oracleModule),
            address(riskModule),
            address(vaultModule),
            address(nullFee),
            address(fee10),
            address(fee50),
            address(fee100),
            address(fee200),
            paymentAddr,
            ownerSafe,
            operators,
            cfg
        );
    }

    // ── Config loading ──────────────────────────────────────────────────

    function _loadDeployConfig() internal view returns (DeployConfig memory cfg) {
        string memory configPath = string.concat("script/config/deploy-", envName, ".json");
        string memory json = vm.readFile(configPath);

        cfg.submitWindowSec = vm.parseJsonUint(json, ".settlement.submitWindowSec");
        cfg.pendingOpsWindowSec = vm.parseJsonUint(json, ".settlement.pendingOpsWindowSec");
        cfg.feedId = vm.parseJsonString(json, ".redstone.feedId");
        cfg.feedDecimals = vm.parseJsonUint(json, ".redstone.feedDecimals");
        cfg.maxSampleDistanceSec = vm.parseJsonUint(json, ".redstone.maxSampleDistanceSec");
        cfg.futureToleranceSec = vm.parseJsonUint(json, ".redstone.futureToleranceSec");

        // WAD values stored as strings in JSON, parse via parseUnits
        cfg.lambdaWad = _parseWadFromJson(json, ".risk.lambda");
        cfg.kDrawdownWad = _parseWadFromJson(json, ".risk.kDrawdown");
        cfg.enforceAlpha = vm.parseJsonBool(json, ".risk.enforceAlpha");

        cfg.rhoBSWad = _parseWadFromJson(json, ".feeWaterfall.rhoBS");
        cfg.phiLPWad = _parseWadFromJson(json, ".feeWaterfall.phiLP");
        cfg.phiBSWad = _parseWadFromJson(json, ".feeWaterfall.phiBS");
        cfg.phiTRWad = _parseWadFromJson(json, ".feeWaterfall.phiTR");

        cfg.withdrawalLagBatches = vm.parseJsonUint(json, ".withdrawalLagBatches");
        cfg.lpShareName = vm.parseJsonString(json, ".lpShare.name");
        cfg.lpShareSymbol = vm.parseJsonString(json, ".lpShare.symbol");

        cfg.release = vm.parseJsonString(json, ".create2.release");
        cfg.vanityPrefix = vm.parseJsonString(json, ".create2.vanityPrefix");
        cfg.maxNonce = vm.parseJsonUint(json, ".create2.maxNonce");
    }

    function _parseWadFromJson(string memory json, string memory key) internal pure returns (uint256) {
        string memory value = vm.parseJsonString(json, key);
        return _parseDecimalToWad(value);
    }

    /// @dev Parse a decimal string like "0.3" to WAD (18 decimals)
    function _parseDecimalToWad(string memory value) internal pure returns (uint256) {
        bytes memory b = bytes(value);
        uint256 dotIndex = type(uint256).max;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                dotIndex = i;
                break;
            }
        }

        if (dotIndex == type(uint256).max) {
            // No decimal point — whole number
            return vm.parseUint(value) * 1e18;
        }

        // Parse integer part
        uint256 intPart = 0;
        if (dotIndex > 0) {
            bytes memory intBytes = new bytes(dotIndex);
            for (uint256 i = 0; i < dotIndex; i++) {
                intBytes[i] = b[i];
            }
            intPart = vm.parseUint(string(intBytes));
        }

        // Parse fractional part
        uint256 fracLen = b.length - dotIndex - 1;
        uint256 fracPart = 0;
        if (fracLen > 0) {
            bytes memory fracBytes = new bytes(fracLen);
            for (uint256 i = 0; i < fracLen; i++) {
                fracBytes[i] = b[dotIndex + 1 + i];
            }
            fracPart = vm.parseUint(string(fracBytes));
        }

        // Scale to 18 decimals
        require(fracLen <= 18, "Too many decimal places (max 18)");
        uint256 fracScale = 10 ** (18 - fracLen);
        return intPart * 1e18 + fracPart * fracScale;
    }

    // ── Resolution helpers ──────────────────────────────────────────────

    function _resolvePaymentToken(address deployer, uint256 deployerKey) internal returns (address) {
        address paymentAddr = vm.envOr("PAYMENT_TOKEN_ADDRESS", address(0));

        if (paymentAddr != address(0)) {
            require(IERC20Metadata(paymentAddr).decimals() == 6, "Payment token must have 6 decimals");
            return paymentAddr;
        }

        // Prod requires explicit payment token
        require(keccak256(bytes(envName)) != keccak256("prod"), "PAYMENT_TOKEN_ADDRESS required for prod");

        // Deploy mock for local/dev
        vm.startBroadcast(deployerKey);
        SignalsUSDToken mock = new SignalsUSDToken();
        vm.stopBroadcast();

        console.log("[deploy] deployed mock PaymentToken=%s", address(mock));
        return address(mock);
    }

    function _resolveOperators(address deployer) internal view returns (address[] memory) {
        string memory operatorsJson = vm.envOr("OPERATORS_JSON", string(""));
        if (bytes(operatorsJson).length > 0) {
            return vm.parseJsonAddressArray(operatorsJson, ".");
        }
        // Default: deployer is the operator
        address[] memory ops = new address[](1);
        ops[0] = deployer;
        return ops;
    }

    function _resolveImpl(string memory envKey) internal view returns (address) {
        address existing = _tryContractAddr(envKey);
        if (existing != address(0) && existing.code.length > 0) {
            console.log("[deploy] reusing %s=%s", envKey, existing);
            return existing;
        }
        return address(0); // Caller will deploy
    }

    function _resolveCreate2Factory(address deployer) internal returns (address) {
        // Try both keys
        address existing = _tryContractAddr("SignalsCreate2Factory");
        if (existing == address(0)) existing = _tryContractAddr("Create2Factory");

        if (existing != address(0) && existing.code.length > 0) {
            console.log("[deploy] reusing Create2Factory=%s", existing);
            return existing;
        }

        // Prod requires existing factory
        require(keccak256(bytes(envName)) != keccak256("prod"), "Create2Factory not found for prod");

        // Deploy new for local/dev (already in broadcast)
        SignalsCreate2Factory f = new SignalsCreate2Factory(deployer);
        console.log("[deploy] deployed Create2Factory=%s", address(f));
        return address(f);
    }

    // ── CREATE2 helpers ─────────────────────────────────────────────────

    function _buildBase(string memory component, string memory release) internal view returns (string memory) {
        return string.concat("signals-v1|", vm.toString(block.chainid), "|", envName, "|", release, "|", component);
    }

    function _buildSalt(string memory base, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base, "|", vm.toString(nonce)));
    }

    function _proxyInitCodeHash(address impl) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, "")));
    }

    function _matchesPrefix(address addr, bytes memory prefix) internal pure returns (bool) {
        bytes memory addrStr = bytes(vm.toLowercase(vm.toString(addr)));
        if (addrStr.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            bytes1 a = prefix[i];
            bytes1 b = addrStr[i];
            if (a >= 0x41 && a <= 0x5A) a = bytes1(uint8(a) + 32);
            if (b >= 0x41 && b <= 0x5A) b = bytes1(uint8(b) + 32);
            if (a != b) return false;
        }
        return true;
    }

    // ── Output ──────────────────────────────────────────────────────────

    function _writeDeployOutput(
        address deployer,
        address factoryAddr,
        address deployerAddr,
        address coreAddr,
        address positionAddr,
        address lpShareAddr,
        address coreImplAddr,
        address positionImplAddr,
        address lpShareImplAddr,
        address tradeModuleAddr,
        address lifecycleModuleAddr,
        address oracleModuleAddr,
        address riskModuleAddr,
        address vaultModuleAddr,
        address nullFeeAddr,
        address fee10Addr,
        address fee50Addr,
        address fee100Addr,
        address fee200Addr,
        address paymentAddr,
        address ownerSafe,
        address[] memory operators,
        DeployConfig memory cfg
    ) internal {
        string memory contracts = vm.serializeAddress("deploy-contracts", "SignalsCreate2Factory", factoryAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsDeployer", deployerAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsCoreProxy", coreAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsCoreImplementation", coreImplAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsPositionProxy", positionAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsPositionImplementation", positionImplAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsLPShareProxy", lpShareAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsLPShareImplementation", lpShareImplAddr);
        contracts = vm.serializeAddress("deploy-contracts", "SignalsLPShare", lpShareAddr);
        contracts = vm.serializeAddress("deploy-contracts", "TradeModule", tradeModuleAddr);
        contracts = vm.serializeAddress("deploy-contracts", "MarketLifecycleModule", lifecycleModuleAddr);
        contracts = vm.serializeAddress("deploy-contracts", "OracleModule", oracleModuleAddr);
        contracts = vm.serializeAddress("deploy-contracts", "RiskModule", riskModuleAddr);
        contracts = vm.serializeAddress("deploy-contracts", "LPVaultModule", vaultModuleAddr);
        contracts = vm.serializeAddress("deploy-contracts", "FeePolicyNull", nullFeeAddr);
        contracts = vm.serializeAddress("deploy-contracts", "FeePolicy10bps", fee10Addr);
        contracts = vm.serializeAddress("deploy-contracts", "FeePolicy50bps", fee50Addr);
        contracts = vm.serializeAddress("deploy-contracts", "FeePolicy100bps", fee100Addr);
        contracts = vm.serializeAddress("deploy-contracts", "FeePolicy200bps", fee200Addr);
        contracts = vm.serializeAddress("deploy-contracts", "PaymentToken", paymentAddr);

        uint256 claimDelay = cfg.submitWindowSec + cfg.pendingOpsWindowSec;
        string memory config = vm.serializeUint("deploy-config", "settlementSubmitWindow", cfg.submitWindowSec);
        config = vm.serializeUint("deploy-config", "pendingOpsWindow", cfg.pendingOpsWindowSec);
        config = vm.serializeUint("deploy-config", "settlementFinalizeDeadline", claimDelay);
        config = vm.serializeString("deploy-config", "redstoneFeedId", cfg.feedId);
        config = vm.serializeUint("deploy-config", "redstoneFeedDecimals", cfg.feedDecimals);
        config = vm.serializeUint("deploy-config", "redstoneMaxSampleDistance", cfg.maxSampleDistanceSec);
        config = vm.serializeUint("deploy-config", "redstoneFutureTolerance", cfg.futureToleranceSec);
        config = vm.serializeString("deploy-config", "lpShareTokenName", cfg.lpShareName);
        config = vm.serializeString("deploy-config", "lpShareTokenSymbol", cfg.lpShareSymbol);
        config = vm.serializeAddress("deploy-config", "deployerEOA", deployer);
        // owners sub-object
        string memory owners = vm.serializeAddress("deploy-owners", "core", ownerSafe);
        owners = vm.serializeAddress("deploy-owners", "position", ownerSafe);
        owners = vm.serializeAddress("deploy-owners", "lpShare", ownerSafe);
        config = vm.serializeString("deploy-config", "owners", owners);

        string memory root = vm.serializeString("root", "action", "deploy");
        root = vm.serializeString("root", "contracts", contracts);
        root = vm.serializeString("root", "config", config);
        root = vm.serializeAddress("root", "deployer", deployer);

        _writeOutput("deploy", root);
    }
}
