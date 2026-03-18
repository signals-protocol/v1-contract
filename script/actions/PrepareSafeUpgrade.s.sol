// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {TradeModule} from "../../contracts/modules/TradeModule.sol";
import {MarketLifecycleModule} from "../../contracts/modules/MarketLifecycleModule.sol";
import {OracleModule} from "../../contracts/modules/OracleModule.sol";
import {RiskModule} from "../../contracts/modules/RiskModule.sol";
import {LPVaultModule} from "../../contracts/modules/LPVaultModule.sol";
import {console} from "forge-std/console.sol";

/// @title PrepareSafeUpgrade — Deploy new impl + modules, output Safe TX calldata
/// @notice Env vars:
///   ENV          — dev|prod (required)
///   PRIVATE_KEY  — deployer key (required)
///   MODULES      — comma-separated list: trade,lifecycle,oracle,risk,vault (default: trade,lifecycle,vault)
contract PrepareSafeUpgrade is BaseScript {
    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");

        // Parse which modules to deploy
        bool deployTrade;
        bool deployLifecycle;
        bool deployOracle;
        bool deployRisk;
        bool deployVault;
        (deployTrade, deployLifecycle, deployOracle, deployRisk, deployVault) = _parseModules();

        // Read existing addresses from env JSON
        address existingTrade = _contractAddr("TradeModule");
        address existingLifecycle = _contractAddr("MarketLifecycleModule");
        address existingOracle = _contractAddr("OracleModule");
        address existingRisk = _contractAddr("RiskModule");
        address existingVault = _tryContractAddr("LPVaultModule");
        if (existingVault == address(0)) existingVault = _contractAddr("VaultModule");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("[prepare-safe-upgrade] deployer=%s", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy new SignalsCore implementation
        SignalsCore coreImpl = new SignalsCore();
        address newCoreImpl = address(coreImpl);
        console.log("[prepare-safe-upgrade] SignalsCoreImpl=%s", newCoreImpl);

        // NOTE: LazyMulSegmentTree (library) is auto-linked and auto-deployed by
        // Foundry when Trade/Lifecycle modules are deployed. The library address
        // is captured from broadcast output via post-deploy.ts.

        // 2. Deploy modules as selected
        address tradeModule = existingTrade;
        if (deployTrade) {
            TradeModule m = new TradeModule();
            tradeModule = address(m);
            console.log("[prepare-safe-upgrade] TradeModule=%s", tradeModule);
        }

        address lifecycleModule = existingLifecycle;
        if (deployLifecycle) {
            MarketLifecycleModule m = new MarketLifecycleModule();
            lifecycleModule = address(m);
            console.log("[prepare-safe-upgrade] MarketLifecycleModule=%s", lifecycleModule);
        }

        address oracleModule = existingOracle;
        if (deployOracle) {
            OracleModule m = new OracleModule();
            oracleModule = address(m);
            console.log("[prepare-safe-upgrade] OracleModule=%s", oracleModule);
        }

        address riskModule = existingRisk;
        if (deployRisk) {
            RiskModule m = new RiskModule();
            riskModule = address(m);
            console.log("[prepare-safe-upgrade] RiskModule=%s", riskModule);
        }

        address vaultModule = existingVault;
        if (deployVault) {
            LPVaultModule m = new LPVaultModule();
            vaultModule = address(m);
            console.log("[prepare-safe-upgrade] LPVaultModule=%s", vaultModule);
        }

        vm.stopBroadcast();

        // 4. Encode calldata
        bytes memory setModulesCalldata = abi.encodeCall(
            SignalsCore.setModules,
            (tradeModule, lifecycleModule, riskModule, vaultModule, oracleModule)
        );
        bytes memory upgradeToAndCallCalldata = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            newCoreImpl,
            setModulesCalldata
        );

        // 5. Write plan JSON
        string memory plan = _buildPlanJson(
            coreProxy,
            newCoreImpl,
            tradeModule,
            lifecycleModule,
            oracleModule,
            riskModule,
            vaultModule,
            setModulesCalldata,
            upgradeToAndCallCalldata,
            deployer
        );
        string memory releasesDir = string.concat("releases/", envName);
        vm.createDir(releasesDir, true);
        string memory planPath = string.concat(releasesDir, "/safe-upgrade-plan.json");
        vm.writeFile(planPath, plan);
        console.log("[prepare-safe-upgrade] plan saved: %s", planPath);

        // 6. Write copy files for Safe manual execution
        string memory copyDir = string.concat(releasesDir, "/safe-upgrade-copy");
        vm.createDir(copyDir, true);
        vm.writeFile(string.concat(copyDir, "/01-to.txt"), vm.toString(coreProxy));
        vm.writeFile(string.concat(copyDir, "/02-value.txt"), "0");
        vm.writeFile(
            string.concat(copyDir, "/03-method.txt"),
            "upgradeToAndCall(address newImplementation, bytes data)"
        );
        vm.writeFile(string.concat(copyDir, "/04-arg-newImplementation.txt"), vm.toString(newCoreImpl));
        vm.writeFile(string.concat(copyDir, "/05-arg-data-setModulesCalldata.txt"), vm.toString(setModulesCalldata));
        vm.writeFile(
            string.concat(copyDir, "/06-calldata-upgradeToAndCall.txt"),
            vm.toString(upgradeToAndCallCalldata)
        );
        console.log("[prepare-safe-upgrade] copy files: %s", copyDir);

        // 7. Print Safe manual execution instructions
        console.log("==============================================");
        console.log("Safe Manual Execution [OWNER ONLY]");
        console.log("==============================================");
        console.log("1) Safe -> New Transaction -> Contract Interaction");
        console.log("2) To = Core proxy, Value = 0");
        console.log("3) Paste ABI, choose upgradeToAndCall");
        console.log("4) Fill args or paste calldata in Data field");

        // 8. Write script output for post-deploy.ts
        // NOTE: LazyMulSegmentTree address comes from broadcast JSON (auto-deployed library),
        // captured by: yarn post-deploy <env> prepare-safe-upgrade --broadcast-dir broadcast/...
        string memory contracts = vm.serializeAddress("prepare-safe-upgrade", "SignalsCoreImplementation", newCoreImpl);
        contracts = vm.serializeAddress("prepare-safe-upgrade", "TradeModule", tradeModule);
        contracts = vm.serializeAddress("prepare-safe-upgrade", "MarketLifecycleModule", lifecycleModule);
        contracts = vm.serializeAddress("prepare-safe-upgrade", "OracleModule", oracleModule);
        contracts = vm.serializeAddress("prepare-safe-upgrade", "RiskModule", riskModule);
        contracts = vm.serializeAddress("prepare-safe-upgrade", "LPVaultModule", vaultModule);

        string memory root = vm.serializeString("root", "action", "prepare-safe-upgrade");
        root = vm.serializeAddress("root", "deployer", deployer);
        root = vm.serializeString("root", "contracts", contracts);

        _writeOutput("prepare-safe-upgrade", root);
    }

    function _parseModules() internal view returns (bool trade, bool lifecycle, bool oracle, bool risk, bool vault) {
        string memory raw = vm.envOr("MODULES", string(""));
        if (bytes(raw).length == 0) {
            // Default: trade, lifecycle, vault
            return (true, true, false, false, true);
        }

        // Parse comma-separated list
        trade = _containsModule(raw, "trade");
        lifecycle = _containsModule(raw, "lifecycle");
        oracle = _containsModule(raw, "oracle");
        risk = _containsModule(raw, "risk");
        vault = _containsModule(raw, "vault");

        require(trade || lifecycle || oracle || risk || vault, "MODULES set but no valid module parsed");
    }

    function _containsModule(string memory raw, string memory module) internal pure returns (bool) {
        bytes memory rawBytes = bytes(raw);
        bytes memory moduleBytes = bytes(module);
        uint256 rawLen = rawBytes.length;
        uint256 modLen = moduleBytes.length;
        if (modLen > rawLen) return false;

        for (uint256 i = 0; i <= rawLen - modLen; i++) {
            bool found = true;
            for (uint256 j = 0; j < modLen; j++) {
                // Case-insensitive compare
                bytes1 a = rawBytes[i + j];
                bytes1 b = moduleBytes[j];
                if (a >= 0x41 && a <= 0x5A) a = bytes1(uint8(a) + 32);
                if (a != b) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function _buildPlanJson(
        address coreProxy,
        address newCoreImpl,
        address tradeModule,
        address lifecycleModule,
        address oracleModule,
        address riskModule,
        address vaultModule,
        bytes memory setModulesCalldata,
        bytes memory upgradeToAndCallCalldata,
        address deployer
    ) internal returns (string memory) {
        // Build deployed object
        string memory deployed = vm.serializeAddress("deployed", "SignalsCoreImplementation", newCoreImpl);
        deployed = vm.serializeAddress("deployed", "TradeModule", tradeModule);
        deployed = vm.serializeAddress("deployed", "MarketLifecycleModule", lifecycleModule);
        deployed = vm.serializeAddress("deployed", "OracleModule", oracleModule);
        deployed = vm.serializeAddress("deployed", "RiskModule", riskModule);
        deployed = vm.serializeAddress("deployed", "LPVaultModule", vaultModule);

        // Build safe.args object
        string memory safeArgs = vm.serializeAddress("safe_args", "newImplementation", newCoreImpl);
        safeArgs = vm.serializeString("safe_args", "data", vm.toString(setModulesCalldata));

        // Build safe object
        string memory safe = vm.serializeAddress("safe", "to", coreProxy);
        safe = vm.serializeString("safe", "value", "0");
        safe = vm.serializeString("safe", "method", "upgradeToAndCall(address newImplementation, bytes data)");
        safe = vm.serializeString("safe", "args", safeArgs);
        safe = vm.serializeString("safe", "calldata", vm.toString(upgradeToAndCallCalldata));

        // Build root
        string memory root = vm.serializeString("plan", "network", envName);
        root = vm.serializeUint("plan", "chainId", block.chainid);
        root = vm.serializeAddress("plan", "deployer", deployer);
        root = vm.serializeAddress("plan", "coreProxy", coreProxy);
        root = vm.serializeString("plan", "deployed", deployed);
        root = vm.serializeString("plan", "safe", safe);

        return root;
    }
}
