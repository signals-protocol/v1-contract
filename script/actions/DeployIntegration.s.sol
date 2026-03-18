// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {TradeModule} from "../../contracts/modules/TradeModule.sol";
import {MarketLifecycleModule} from "../../contracts/modules/MarketLifecycleModule.sol";
import {RiskModule} from "../../contracts/modules/RiskModule.sol";
import {LPVaultModule} from "../../contracts/modules/LPVaultModule.sol";
import {SignalsCoreHarness} from "../../contracts/testonly/SignalsCoreHarness.sol";
import {OracleModuleHarness} from "../../contracts/testonly/OracleModuleHarness.sol";
import {TestERC1967Proxy} from "../../contracts/testonly/TestERC1967Proxy.sol";
import {MockFeePolicy} from "../../contracts/testonly/MockFeePolicy.sol";
import {SignalsUSDToken} from "../../contracts/testonly/SignalsUSDToken.sol";
import {SignalsPosition} from "../../contracts/position/SignalsPosition.sol";
import {SignalsLPShare} from "../../contracts/tokens/SignalsLPShare.sol";

/// @title DeployIntegration — Deploy all contracts for v1-integration parity tests
/// @notice Self-contained script (no BaseScript) for integration test deployment on Anvil
/// @dev Env vars: PRIVATE_KEY, OPERATORS_JSON (optional, e.g. '["0x..."]')
contract DeployIntegration is Script {
    struct IntegrationConfig {
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
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("[deploy-integration] deployer=%s", deployer);

        IntegrationConfig memory cfg = _loadConfig();
        address[] memory operators = _resolveOperators(deployer);

        vm.startBroadcast(deployerKey);

        // ── 1. Payment token (mock 6-decimal USDC) ────────────────────────
        SignalsUSDToken paymentToken = new SignalsUSDToken();

        // ── 2. Modules (Foundry auto-links LazyMulSegmentTree library) ────
        TradeModule tradeModule = new TradeModule();
        MarketLifecycleModule lifecycleModule = new MarketLifecycleModule();
        RiskModule riskModule = new RiskModule();
        OracleModuleHarness oracleModule = new OracleModuleHarness();
        LPVaultModule vaultModule = new LPVaultModule();

        // ── 3. Fee policy (zero fee for base parity tests) ────────────────
        MockFeePolicy feePolicy = new MockFeePolicy(0);

        // ── 4. Implementation contracts ───────────────────────────────────
        SignalsCoreHarness coreImpl = new SignalsCoreHarness();
        SignalsPosition positionImpl = new SignalsPosition();
        SignalsLPShare lpShareImpl = new SignalsLPShare();

        // ── 5. Proxies (simple ERC1967, not CREATE2) ──────────────────────
        TestERC1967Proxy coreProxy = new TestERC1967Proxy(address(coreImpl), "");
        TestERC1967Proxy positionProxy = new TestERC1967Proxy(address(positionImpl), "");
        TestERC1967Proxy lpShareProxy = new TestERC1967Proxy(address(lpShareImpl), "");

        // ── 6. Initialize ─────────────────────────────────────────────────
        SignalsCoreHarness core = SignalsCoreHarness(address(coreProxy));
        SignalsPosition position = SignalsPosition(address(positionProxy));
        SignalsLPShare lpShare = SignalsLPShare(address(lpShareProxy));

        uint256 claimDelay = cfg.submitWindowSec + cfg.pendingOpsWindowSec;

        SignalsCore.InitParams memory params = SignalsCore.InitParams({
            paymentToken: address(paymentToken),
            positionContract: address(positionProxy),
            lpShareToken: address(lpShareProxy),
            tradeModule: address(tradeModule),
            lifecycleModule: address(lifecycleModule),
            riskModule: address(riskModule),
            vaultModule: address(vaultModule),
            oracleModule: address(oracleModule),
            ownerSafe: deployer,
            settlementSubmitWindow: uint64(cfg.submitWindowSec),
            pendingOpsWindow: uint64(cfg.pendingOpsWindowSec),
            claimDelaySeconds: uint64(claimDelay),
            redstoneFeedId: bytes32(bytes(cfg.feedId)),
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

        core.initialize(params);
        position.initialize(address(coreProxy), deployer);
        lpShare.initialize(address(coreProxy), address(paymentToken), "Signals LP", "SIGLP", deployer);

        // ── 7. Fund backstop + seed vault ─────────────────────────────────
        // 1M USDC (6 decimals) = 1_000_000 * 10^6 = 1e12
        uint256 backstopAmount = 1_000_000 * 1e6;
        // Raw amount, NOT scaled by decimals
        uint256 vaultSeedAmount = 1_000_000_000;

        paymentToken.approve(address(coreProxy), backstopAmount + vaultSeedAmount);
        core.fundBackstop(backstopAmount);
        core.seedVault(vaultSeedAmount);

        vm.stopBroadcast();

        console.log("[deploy-integration] coreProxy=%s", address(coreProxy));
        console.log("[deploy-integration] positionProxy=%s", address(positionProxy));
        console.log("[deploy-integration] lpShareProxy=%s", address(lpShareProxy));

        // ── 8. Write output ───────────────────────────────────────────────
        _writeOutput(
            deployer,
            address(coreProxy),
            address(coreImpl),
            address(positionProxy),
            address(positionImpl),
            address(lpShareProxy),
            address(lpShareImpl),
            address(tradeModule),
            address(lifecycleModule),
            address(riskModule),
            address(oracleModule),
            address(vaultModule),
            address(feePolicy),
            address(paymentToken)
        );
    }

    // ── Config loading ────────────────────────────────────────────────────

    function _loadConfig() internal view returns (IntegrationConfig memory cfg) {
        string memory json = vm.readFile("script/config/deploy-integration.json");

        cfg.submitWindowSec = vm.parseJsonUint(json, ".settlement.submitWindowSec");
        cfg.pendingOpsWindowSec = vm.parseJsonUint(json, ".settlement.pendingOpsWindowSec");
        cfg.feedId = vm.parseJsonString(json, ".redstone.feedId");
        cfg.feedDecimals = vm.parseJsonUint(json, ".redstone.feedDecimals");
        cfg.maxSampleDistanceSec = vm.parseJsonUint(json, ".redstone.maxSampleDistanceSec");
        cfg.futureToleranceSec = vm.parseJsonUint(json, ".redstone.futureToleranceSec");

        cfg.lambdaWad = _parseWadFromJson(json, ".risk.lambda");
        cfg.kDrawdownWad = _parseWadFromJson(json, ".risk.kDrawdown");
        cfg.enforceAlpha = vm.parseJsonBool(json, ".risk.enforceAlpha");

        cfg.rhoBSWad = _parseWadFromJson(json, ".feeWaterfall.rhoBS");
        cfg.phiLPWad = _parseWadFromJson(json, ".feeWaterfall.phiLP");
        cfg.phiBSWad = _parseWadFromJson(json, ".feeWaterfall.phiBS");
        cfg.phiTRWad = _parseWadFromJson(json, ".feeWaterfall.phiTR");

        cfg.withdrawalLagBatches = vm.parseJsonUint(json, ".withdrawalLagBatches");
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
            return vm.parseUint(value) * 1e18;
        }

        uint256 intPart = 0;
        if (dotIndex > 0) {
            bytes memory intBytes = new bytes(dotIndex);
            for (uint256 i = 0; i < dotIndex; i++) {
                intBytes[i] = b[i];
            }
            intPart = vm.parseUint(string(intBytes));
        }

        uint256 fracLen = b.length - dotIndex - 1;
        uint256 fracPart = 0;
        if (fracLen > 0) {
            bytes memory fracBytes = new bytes(fracLen);
            for (uint256 i = 0; i < fracLen; i++) {
                fracBytes[i] = b[dotIndex + 1 + i];
            }
            fracPart = vm.parseUint(string(fracBytes));
        }

        require(fracLen <= 18, "Too many decimal places (max 18)");
        uint256 fracScale = 10 ** (18 - fracLen);
        return intPart * 1e18 + fracPart * fracScale;
    }

    // ── Operator resolution ───────────────────────────────────────────────

    function _resolveOperators(address deployer) internal view returns (address[] memory) {
        string memory operatorsJson = vm.envOr("OPERATORS_JSON", string(""));
        if (bytes(operatorsJson).length > 0) {
            return vm.parseJsonAddressArray(operatorsJson, ".");
        }
        address[] memory ops = new address[](1);
        ops[0] = deployer;
        return ops;
    }

    // ── Output ────────────────────────────────────────────────────────────

    function _writeOutput(
        address deployer,
        address coreProxy,
        address coreImpl,
        address positionProxy,
        address positionImpl,
        address lpShareProxy,
        address lpShareImpl,
        address tradeModule,
        address lifecycleModule,
        address riskModule,
        address oracleModule,
        address vaultModule,
        address feePolicy,
        address paymentToken
    ) internal {
        string memory json = vm.serializeAddress("out", "SignalsCore", coreProxy);
        json = vm.serializeAddress("out", "SignalsCoreImpl", coreImpl);
        json = vm.serializeAddress("out", "SignalsPosition", positionProxy);
        json = vm.serializeAddress("out", "SignalsPositionImpl", positionImpl);
        json = vm.serializeAddress("out", "SignalsLPShare", lpShareProxy);
        json = vm.serializeAddress("out", "SignalsLPShareImpl", lpShareImpl);
        json = vm.serializeAddress("out", "TradeModule", tradeModule);
        json = vm.serializeAddress("out", "MarketLifecycleModule", lifecycleModule);
        json = vm.serializeAddress("out", "RiskModule", riskModule);
        json = vm.serializeAddress("out", "OracleModule", oracleModule);
        json = vm.serializeAddress("out", "LPVaultModule", vaultModule);
        json = vm.serializeAddress("out", "LazyMulSegmentTree", address(0));
        json = vm.serializeAddress("out", "FeePolicy", feePolicy);
        json = vm.serializeAddress("out", "PaymentToken", paymentToken);
        json = vm.serializeAddress("out", "deployer", deployer);
        vm.writeFile("script-output/deploy-integration.json", json);
        console.log("[deploy-integration] output written to script-output/deploy-integration.json");
    }
}
