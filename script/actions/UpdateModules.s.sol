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

/// @title UpdateModules — Deploy selected modules and call setModules
/// @notice Individual bool env vars control which modules to update:
///   UPDATE_TRADE=1  UPDATE_LIFECYCLE=1  UPDATE_ORACLE=1  UPDATE_RISK=1  UPDATE_VAULT=1
///   Default (all false): updates Trade, Lifecycle, Oracle
contract UpdateModules is BaseScript {
    function run() external {
        _enforceChainId();

        address coreProxyAddr = _contractAddr("SignalsCoreProxy");
        SignalsCore core = SignalsCore(coreProxyAddr);

        // Determine which modules to update
        bool anyExplicit = vm.envOr("UPDATE_TRADE", false) || vm.envOr("UPDATE_LIFECYCLE", false)
            || vm.envOr("UPDATE_ORACLE", false) || vm.envOr("UPDATE_RISK", false) || vm.envOr("UPDATE_VAULT", false);

        bool updateTrade = anyExplicit ? vm.envOr("UPDATE_TRADE", false) : true;
        bool updateLifecycle = anyExplicit ? vm.envOr("UPDATE_LIFECYCLE", false) : true;
        bool updateOracle = anyExplicit ? vm.envOr("UPDATE_ORACLE", false) : true;
        bool updateRisk = vm.envOr("UPDATE_RISK", false);
        bool updateVault = vm.envOr("UPDATE_VAULT", false);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // Deploy new modules as needed
        address tradeAddr = _tryContractAddr("TradeModule");
        address lifecycleAddr = _tryContractAddr("MarketLifecycleModule");
        address oracleAddr = _tryContractAddr("OracleModule");
        address riskAddr = _tryContractAddr("RiskModule");
        address vaultAddr = _tryContractAddr("LPVaultModule");
        if (vaultAddr == address(0)) vaultAddr = _tryContractAddr("VaultModule");

        if (updateTrade) {
            TradeModule m = new TradeModule();
            tradeAddr = address(m);
            console.log("[update-modules] deployed TradeModule=%s", tradeAddr);
        }
        if (updateLifecycle) {
            MarketLifecycleModule m = new MarketLifecycleModule();
            lifecycleAddr = address(m);
            console.log("[update-modules] deployed MarketLifecycleModule=%s", lifecycleAddr);
        }
        if (updateOracle) {
            OracleModule m = new OracleModule();
            oracleAddr = address(m);
            console.log("[update-modules] deployed OracleModule=%s", oracleAddr);
        }
        if (updateRisk) {
            RiskModule m = new RiskModule();
            riskAddr = address(m);
            console.log("[update-modules] deployed RiskModule=%s", riskAddr);
        }
        if (updateVault) {
            LPVaultModule m = new LPVaultModule();
            vaultAddr = address(m);
            console.log("[update-modules] deployed LPVaultModule=%s", vaultAddr);
        }

        require(tradeAddr != address(0), "TradeModule address missing");
        require(lifecycleAddr != address(0), "MarketLifecycleModule address missing");
        require(oracleAddr != address(0), "OracleModule address missing");

        // Fallback to current on-chain module addresses if not updating and env JSON missing
        if (riskAddr == address(0)) riskAddr = core.riskModule();
        if (vaultAddr == address(0)) vaultAddr = core.vaultModule();

        core.setModules(tradeAddr, lifecycleAddr, riskAddr, vaultAddr, oracleAddr);

        vm.stopBroadcast();

        // Write output for post-deploy.ts
        string memory contracts = vm.serializeAddress("update-modules", "TradeModule", tradeAddr);
        contracts = vm.serializeAddress("update-modules", "MarketLifecycleModule", lifecycleAddr);
        contracts = vm.serializeAddress("update-modules", "OracleModule", oracleAddr);
        if (updateRisk) {
            contracts = vm.serializeAddress("update-modules", "RiskModule", riskAddr);
        }
        if (updateVault) {
            contracts = vm.serializeAddress("update-modules", "LPVaultModule", vaultAddr);
        }

        string memory root = vm.serializeString("root", "action", "update-modules");
        root = vm.serializeAddress("root", "deployer", vm.addr(deployerKey));
        root = vm.serializeString("root", "contracts", contracts);

        _writeOutput("update-modules", root);
    }
}
