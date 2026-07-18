// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

/// @title PrepareDecommissionSweep
/// @notice Emits the exact Safe MultiSend payload for SIG-820: swap vault module, sweep, restore vault module.
/// @dev Reads live module addresses from Core. The only module address sourced from env JSON is DecommissionModule.
contract PrepareDecommissionSweep is BaseScript {
    uint256 internal constant TOTAL_PENDING_DEPOSITS_SLOT = 34;
    uint256 internal constant TOTAL_PAYOUT_RESERVE_SLOT = 35;
    uint256 internal constant TOTAL_PENDING_WITHDRAWALS_SLOT = 36;

    struct WaivedLiabilities {
        uint256 totalPendingDeposits6;
        uint256 totalPayoutReserve6;
        uint256 totalPendingWithdrawals6;
        uint256 totalReservedLiabilities6;
        uint256 corePaymentTokenBalance6;
    }

    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address decommissionModule = _contractAddr("DecommissionModule");
        address multiSendAddress = _multiSendAddress();
        SignalsCore core = SignalsCore(coreProxy);

        address owner = core.owner();
        address expectedOwner = _tryConfigAddr("owners.core");
        if (expectedOwner != address(0)) {
            require(owner == expectedOwner, "Core owner does not match env owners.core");
        }

        address tradeModule = core.tradeModule();
        address lifecycleModule = core.lifecycleModule();
        address riskModule = core.riskModule();
        address restoreVaultModule = core.vaultModule();
        address oracleModule = core.oracleModule();

        _requireContract(tradeModule, "TradeModule");
        _requireContract(lifecycleModule, "MarketLifecycleModule");
        _requireContract(riskModule, "RiskModule");
        _requireContract(decommissionModule, "DecommissionModule");
        _requireContract(restoreVaultModule, "restore LPVaultModule");
        _requireContract(oracleModule, "OracleModule");

        WaivedLiabilities memory waivedLiabilities = _readWaivedLiabilities(coreProxy, core.paymentToken());
        _logWaivedLiabilities(waivedLiabilities);

        bytes memory setDecommissionCalldata = abi.encodeCall(
            SignalsCore.setModules, (tradeModule, lifecycleModule, riskModule, decommissionModule, oracleModule)
        );
        bytes memory withdrawTreasuryCalldata =
            abi.encodeCall(SignalsCore.withdrawTreasury, (waivedLiabilities.corePaymentTokenBalance6));
        bytes memory restoreVaultCalldata = abi.encodeCall(
            SignalsCore.setModules, (tradeModule, lifecycleModule, riskModule, restoreVaultModule, oracleModule)
        );
        bytes memory packedTransactions = bytes.concat(
            _encodeMultiSendTx(coreProxy, setDecommissionCalldata),
            _encodeMultiSendTx(coreProxy, withdrawTreasuryCalldata),
            _encodeMultiSendTx(coreProxy, restoreVaultCalldata)
        );
        bytes memory multiSendCalldata = abi.encodeWithSignature("multiSend(bytes)", packedTransactions);

        string memory plan = _buildPlanJson(
            multiSendAddress,
            coreProxy,
            owner,
            decommissionModule,
            tradeModule,
            lifecycleModule,
            riskModule,
            restoreVaultModule,
            oracleModule,
            setDecommissionCalldata,
            withdrawTreasuryCalldata,
            restoreVaultCalldata,
            multiSendCalldata,
            waivedLiabilities
        );

        string memory releasesDir = string.concat("releases/", envName);
        vm.createDir(releasesDir, true);
        string memory planPath = string.concat(releasesDir, "/decommission-sweep-plan.json");
        vm.writeFile(planPath, plan);
        console.log("[prepare-decommission-sweep] plan saved: %s", planPath);

        string memory copyDir = string.concat(releasesDir, "/decommission-sweep-copy");
        vm.createDir(copyDir, true);
        vm.writeFile(
            string.concat(copyDir, "/00-WAIVED-LIABILITIES-READ-BEFORE-SIGNING.txt"),
            _buildWaivedLiabilitiesCopy(waivedLiabilities)
        );
        vm.writeFile(string.concat(copyDir, "/01-target.txt"), vm.toString(multiSendAddress));
        vm.writeFile(string.concat(copyDir, "/02-arg-operation.txt"), "1");
        vm.writeFile(string.concat(copyDir, "/03-arg-value.txt"), "0");
        vm.writeFile(string.concat(copyDir, "/04-arg-data-multiSendCalldata.txt"), vm.toString(multiSendCalldata));
        vm.writeFile(
            string.concat(copyDir, "/sub-tx-1-setModules-decommission.txt"), vm.toString(setDecommissionCalldata)
        );
        vm.writeFile(string.concat(copyDir, "/sub-tx-2-withdrawTreasury.txt"), vm.toString(withdrawTreasuryCalldata));
        vm.writeFile(string.concat(copyDir, "/sub-tx-3-setModules-restore.txt"), vm.toString(restoreVaultCalldata));
        console.log("[prepare-decommission-sweep] copy files: %s", copyDir);

        console.log("==============================================");
        console.log("Safe Manual Execution [OWNER ONLY]");
        console.log("==============================================");
        console.log("1) Run exact-calldata validation: yarn validate-decommission-sweep:prod");
        console.log("2) Propose the validated sweep: yarn propose-decommission-sweep:prod");
        console.log("3) Safe target = MultiSend, Value = 0, Operation = DelegateCall");
    }

    function _readWaivedLiabilities(address coreProxy, IERC20 paymentToken)
        internal
        view
        returns (WaivedLiabilities memory liabilities)
    {
        liabilities.totalPendingDeposits6 = _readStorageUint(coreProxy, TOTAL_PENDING_DEPOSITS_SLOT);
        liabilities.totalPayoutReserve6 = _readStorageUint(coreProxy, TOTAL_PAYOUT_RESERVE_SLOT);
        liabilities.totalPendingWithdrawals6 = _readStorageUint(coreProxy, TOTAL_PENDING_WITHDRAWALS_SLOT);
        liabilities.totalReservedLiabilities6 =
            liabilities.totalPendingDeposits6 + liabilities.totalPayoutReserve6 + liabilities.totalPendingWithdrawals6;
        liabilities.corePaymentTokenBalance6 = paymentToken.balanceOf(coreProxy);
    }

    function _readStorageUint(address target, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(target, bytes32(slot)));
    }

    function _logWaivedLiabilities(WaivedLiabilities memory liabilities) internal pure {
        console.log("==============================================");
        console.log("WARNING: DECOMMISSION SWEEP WAIVES RESERVED LIABILITIES");
        console.log("This sweep intentionally bypasses the reserved-liability counters below.");
        console.log("Safe signers must explicitly approve this outcome before signing.");
        console.log("_totalPendingDeposits6 slot 34: %s", liabilities.totalPendingDeposits6);
        console.log("_totalPayoutReserve6 slot 35: %s", liabilities.totalPayoutReserve6);
        console.log("_totalPendingWithdrawals6 slot 36: %s", liabilities.totalPendingWithdrawals6);
        console.log("total reserved liabilities: %s", liabilities.totalReservedLiabilities6);
        console.log("Core payment-token balance: %s", liabilities.corePaymentTokenBalance6);
        console.log("==============================================");
    }

    function _buildWaivedLiabilitiesCopy(WaivedLiabilities memory liabilities) internal pure returns (string memory) {
        return string.concat(
            "WARNING: DECOMMISSION SWEEP WAIVES RESERVED LIABILITIES\n",
            "\n",
            "The SIG-820 sweep intentionally bypasses these Core accounting reserves and transfers the full Core ",
            "payment-token balance to the owner Safe. Safe signers must explicitly approve this outcome before signing.\n",
            "\n",
            "_totalPendingDeposits6 (slot 34): ",
            vm.toString(liabilities.totalPendingDeposits6),
            "\n",
            "_totalPayoutReserve6 (slot 35): ",
            vm.toString(liabilities.totalPayoutReserve6),
            "\n",
            "_totalPendingWithdrawals6 (slot 36): ",
            vm.toString(liabilities.totalPendingWithdrawals6),
            "\n",
            "totalReservedLiabilities6: ",
            vm.toString(liabilities.totalReservedLiabilities6),
            "\n",
            "corePaymentTokenBalance6: ",
            vm.toString(liabilities.corePaymentTokenBalance6),
            "\n"
        );
    }

    function _multiSendAddress() internal view returns (address) {
        string memory configPath = string.concat("script/config/deploy-", envName, ".json");
        string memory json = vm.readFile(configPath);
        address multiSend = vm.parseJsonAddress(json, ".safe.multiSendAddress");
        require(multiSend != address(0), "safe.multiSendAddress missing");
        return multiSend;
    }

    function _encodeMultiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), uint256(data.length), data);
    }

    function _requireContract(address target, string memory label) internal view {
        require(target != address(0), string.concat(label, " is zero"));
        require(target.code.length > 0, string.concat(label, " has no code"));
    }

    function _buildPlanJson(
        address multiSendAddress,
        address coreProxy,
        address owner,
        address decommissionModule,
        address tradeModule,
        address lifecycleModule,
        address riskModule,
        address restoreVaultModule,
        address oracleModule,
        bytes memory setDecommissionCalldata,
        bytes memory withdrawTreasuryCalldata,
        bytes memory restoreVaultCalldata,
        bytes memory multiSendCalldata,
        WaivedLiabilities memory waivedLiabilities
    ) internal returns (string memory) {
        string memory deployed = vm.serializeAddress("deployed", "DecommissionModule", decommissionModule);

        string memory modules = vm.serializeAddress("modules", "TradeModule", tradeModule);
        modules = vm.serializeAddress("modules", "MarketLifecycleModule", lifecycleModule);
        modules = vm.serializeAddress("modules", "RiskModule", riskModule);
        modules = vm.serializeAddress("modules", "DecommissionModule", decommissionModule);
        modules = vm.serializeAddress("modules", "RestoreVaultModule", restoreVaultModule);
        modules = vm.serializeAddress("modules", "OracleModule", oracleModule);

        string memory subTx1 = vm.serializeAddress("sub_tx_1", "to", coreProxy);
        subTx1 = vm.serializeString("sub_tx_1", "value", "0");
        subTx1 = vm.serializeUint("sub_tx_1", "operation", 0);
        subTx1 = vm.serializeString("sub_tx_1", "data", vm.toString(setDecommissionCalldata));

        string memory subTx2 = vm.serializeAddress("sub_tx_2", "to", coreProxy);
        subTx2 = vm.serializeString("sub_tx_2", "value", "0");
        subTx2 = vm.serializeUint("sub_tx_2", "operation", 0);
        subTx2 = vm.serializeString("sub_tx_2", "data", vm.toString(withdrawTreasuryCalldata));

        string memory subTx3 = vm.serializeAddress("sub_tx_3", "to", coreProxy);
        subTx3 = vm.serializeString("sub_tx_3", "value", "0");
        subTx3 = vm.serializeUint("sub_tx_3", "operation", 0);
        subTx3 = vm.serializeString("sub_tx_3", "data", vm.toString(restoreVaultCalldata));

        string memory subTxs = vm.serializeString("sub_transactions", "setModulesToDecommission", subTx1);
        subTxs = vm.serializeString("sub_transactions", "withdrawTreasury", subTx2);
        subTxs = vm.serializeString("sub_transactions", "setModulesRestore", subTx3);

        string memory safeArgs = vm.serializeAddress("safe_args", "to", multiSendAddress);
        safeArgs = vm.serializeString("safe_args", "value", "0");
        safeArgs = vm.serializeUint("safe_args", "operation", 1);
        safeArgs = vm.serializeString("safe_args", "data", vm.toString(multiSendCalldata));

        string memory safe = vm.serializeAddress("safe", "to", multiSendAddress);
        safe = vm.serializeString("safe", "value", "0");
        safe = vm.serializeUint("safe", "operation", 1);
        safe = vm.serializeString("safe", "method", "multiSend(bytes)");
        safe = vm.serializeString("safe", "calldata", vm.toString(multiSendCalldata));

        string memory liabilities =
            vm.serializeUint("waived_liabilities", "totalPendingDeposits6", waivedLiabilities.totalPendingDeposits6);
        liabilities =
            vm.serializeUint("waived_liabilities", "totalPayoutReserve6", waivedLiabilities.totalPayoutReserve6);
        liabilities = vm.serializeUint(
            "waived_liabilities", "totalPendingWithdrawals6", waivedLiabilities.totalPendingWithdrawals6
        );
        liabilities = vm.serializeUint(
            "waived_liabilities", "totalReservedLiabilities6", waivedLiabilities.totalReservedLiabilities6
        );
        liabilities = vm.serializeUint(
            "waived_liabilities", "corePaymentTokenBalance6", waivedLiabilities.corePaymentTokenBalance6
        );
        liabilities = vm.serializeString(
            "waived_liabilities",
            "warning",
            "The SIG-820 sweep intentionally bypasses these reserved liabilities and transfers the full Core payment-token balance to the owner Safe."
        );

        string memory root = vm.serializeString("plan", "network", envName);
        root = vm.serializeUint("plan", "chainId", block.chainid);
        root = vm.serializeAddress("plan", "coreProxy", coreProxy);
        root = vm.serializeAddress("plan", "ownerSafe", owner);
        root = vm.serializeString("plan", "deployed", deployed);
        root = vm.serializeString("plan", "modules", modules);
        root = vm.serializeString("plan", "sub_transactions", subTxs);
        root = vm.serializeString("plan", "safe_args", safeArgs);
        root = vm.serializeString("plan", "safe", safe);
        root = vm.serializeString("plan", "waivedLiabilities", liabilities);

        return root;
    }
}
