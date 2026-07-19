// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {console} from "forge-std/console.sol";

/// @title PrepareDecommissionQuiesce
/// @notice Emits the exact Safe MultiSend payload for SIG-820 phase 1: pause Core and revoke configured operators.
contract PrepareDecommissionQuiesce is BaseScript {
    struct QuiescePayload {
        bool includePause;
        address[] activeOperators;
        bytes pauseCalldata;
        bytes[] revokeOperatorCalldatas;
        bytes packedTransactions;
        bytes multiSendCalldata;
    }

    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address multiSendAddress = _multiSendAddress();
        SignalsCore core = SignalsCore(coreProxy);

        address owner = core.owner();
        address expectedOwner = _tryConfigAddr("owners.core");
        if (expectedOwner != address(0)) {
            require(owner == expectedOwner, "Core owner does not match env owners.core");
        }

        address[] memory operators = _tryConfigAddrArray("operatorAllowlist");
        QuiescePayload memory payload = _buildQuiescePayload(coreProxy, core, operators);
        _requireQuiesceActions(payload);

        string memory plan = _buildPlanJson(
            multiSendAddress,
            coreProxy,
            owner,
            operators.length,
            payload.includePause,
            payload.activeOperators,
            payload.pauseCalldata,
            payload.revokeOperatorCalldatas,
            payload.multiSendCalldata
        );

        string memory releasesDir = string.concat("releases/", envName);
        vm.createDir(releasesDir, true);
        string memory planPath = string.concat(releasesDir, "/decommission-quiesce-plan.json");
        vm.writeFile(planPath, plan);
        console.log("[prepare-decommission-quiesce] plan saved: %s", planPath);

        string memory copyDir = string.concat(releasesDir, "/decommission-quiesce-copy");
        vm.createDir(copyDir, true);
        vm.writeFile(string.concat(copyDir, "/01-target.txt"), vm.toString(multiSendAddress));
        vm.writeFile(string.concat(copyDir, "/02-arg-operation.txt"), "1");
        vm.writeFile(string.concat(copyDir, "/03-arg-value.txt"), "0");
        vm.writeFile(
            string.concat(copyDir, "/04-arg-data-multiSendCalldata.txt"), vm.toString(payload.multiSendCalldata)
        );
        uint256 nextSubTx = 1;
        if (payload.includePause) {
            vm.writeFile(
                string.concat(copyDir, "/sub-tx-", vm.toString(nextSubTx), "-pause.txt"),
                vm.toString(payload.pauseCalldata)
            );
            nextSubTx++;
        } else {
            vm.writeFile(
                string.concat(copyDir, "/pause-skipped-already-paused.txt"), "Skipped: Core is already paused.\n"
            );
        }
        if (payload.activeOperators.length == 0) {
            vm.writeFile(
                string.concat(copyDir, "/operator-revocations-skipped.txt"),
                operators.length == 0
                    ? "Skipped: config.operatorAllowlist is empty.\n"
                    : "Skipped: configured operators are already revoked.\n"
            );
        } else {
            for (uint256 i = 0; i < payload.activeOperators.length; i++) {
                vm.writeFile(
                    string.concat(copyDir, "/sub-tx-", vm.toString(nextSubTx), "-setOperator-false.txt"),
                    string.concat(
                        "operator: ",
                        vm.toString(payload.activeOperators[i]),
                        "\ncalldata: ",
                        vm.toString(payload.revokeOperatorCalldatas[i]),
                        "\n"
                    )
                );
                nextSubTx++;
            }
        }
        console.log("[prepare-decommission-quiesce] copy files: %s", copyDir);

        console.log("==============================================");
        console.log("Safe Manual Execution [OWNER ONLY]");
        console.log("==============================================");
        console.log("Required order:");
        console.log("1) Prepare quiesce: yarn prepare-decommission-quiesce:prod");
        console.log("2) Validate quiesce: yarn validate-decommission-quiesce:prod");
        console.log("3) Propose and execute quiesce: yarn propose-decommission-quiesce:prod");
        console.log("4) Prepare sweep: yarn prepare-decommission-sweep:prod");
        console.log("5) Validate sweep: yarn validate-decommission-sweep:prod");
        console.log("6) Propose sweep: yarn propose-decommission-sweep:prod");
        console.log("Safe target = MultiSend, Value = 0, Operation = DelegateCall");
    }

    function _multiSendAddress() internal view returns (address) {
        string memory configPath = string.concat("script/config/deploy-", envName, ".json");
        string memory json = vm.readFile(configPath);
        address multiSend = vm.parseJsonAddress(json, ".safe.multiSendAddress");
        require(multiSend != address(0), "safe.multiSendAddress missing");
        return multiSend;
    }

    function _buildQuiescePayload(address coreProxy, SignalsCore core, address[] memory operators)
        internal
        view
        returns (QuiescePayload memory payload)
    {
        _requireOperatorsValid(operators);

        payload.includePause = !core.paused();
        payload.activeOperators = _activeOperators(core, operators);
        payload.pauseCalldata = abi.encodeCall(SignalsCore.pause, ());
        payload.revokeOperatorCalldatas = new bytes[](payload.activeOperators.length);

        if (payload.includePause) {
            payload.packedTransactions = _encodeMultiSendTx(coreProxy, payload.pauseCalldata);
        }
        for (uint256 i = 0; i < payload.activeOperators.length; i++) {
            payload.revokeOperatorCalldatas[i] =
                abi.encodeCall(SignalsCore.setOperator, (payload.activeOperators[i], false));
            payload.packedTransactions = bytes.concat(
                payload.packedTransactions, _encodeMultiSendTx(coreProxy, payload.revokeOperatorCalldatas[i])
            );
        }
        payload.multiSendCalldata = abi.encodeWithSignature("multiSend(bytes)", payload.packedTransactions);
    }

    function _requireQuiesceActions(QuiescePayload memory payload) internal pure {
        require(payload.includePause || payload.activeOperators.length != 0, "Core already fully quiesced");
    }

    function _activeOperators(SignalsCore core, address[] memory operators)
        internal
        view
        returns (address[] memory activeOperators)
    {
        uint256 activeCount;
        for (uint256 i = 0; i < operators.length; i++) {
            if (core.operators(operators[i])) activeCount++;
        }

        activeOperators = new address[](activeCount);
        uint256 cursor;
        for (uint256 i = 0; i < operators.length; i++) {
            if (!core.operators(operators[i])) continue;
            activeOperators[cursor] = operators[i];
            cursor++;
        }
    }

    function _encodeMultiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), uint256(data.length), data);
    }

    function _requireOperatorsValid(address[] memory operators) internal pure {
        for (uint256 i = 0; i < operators.length; i++) {
            require(operators[i] != address(0), "operatorAllowlist contains zero address");
        }
    }

    function _serializeSubTransaction(string memory key, address to, bytes memory data)
        internal
        returns (string memory)
    {
        string memory subTx = vm.serializeAddress(key, "to", to);
        subTx = vm.serializeString(key, "value", "0");
        subTx = vm.serializeUint(key, "operation", 0);
        subTx = vm.serializeString(key, "data", vm.toString(data));
        return subTx;
    }

    function _buildOperatorRevocationsJson(address[] memory activeOperators, uint256 configuredOperatorCount)
        internal
        returns (string memory)
    {
        string memory operatorRevocations =
            vm.serializeUint("quiesce_operator_revocations", "count", activeOperators.length);
        if (configuredOperatorCount == 0) {
            operatorRevocations =
                vm.serializeString("quiesce_operator_revocations", "status", "skipped_no_operator_allowlist");
        } else if (activeOperators.length == 0) {
            operatorRevocations =
                vm.serializeString("quiesce_operator_revocations", "status", "skipped_already_revoked");
        } else {
            operatorRevocations = vm.serializeString("quiesce_operator_revocations", "status", "included_active_only");
            for (uint256 i = 0; i < activeOperators.length; i++) {
                operatorRevocations = vm.serializeAddress(
                    "quiesce_operator_revocations", string.concat("operator", vm.toString(i + 1)), activeOperators[i]
                );
            }
        }
        return operatorRevocations;
    }

    function _buildPlanJson(
        address multiSendAddress,
        address coreProxy,
        address owner,
        uint256 configuredOperatorCount,
        bool includePause,
        address[] memory activeOperators,
        bytes memory pauseCalldata,
        bytes[] memory revokeOperatorCalldatas,
        bytes memory multiSendCalldata
    ) internal returns (string memory) {
        string memory subTxs;
        bool subTxsInitialized;
        if (includePause) {
            subTxs = vm.serializeString(
                "quiesce_sub_transactions",
                "pause",
                _serializeSubTransaction("quiesce_sub_tx_pause", coreProxy, pauseCalldata)
            );
            subTxsInitialized = true;
        }
        for (uint256 i = 0; i < activeOperators.length; i++) {
            subTxs = vm.serializeString(
                "quiesce_sub_transactions",
                string.concat("setOperatorFalse", vm.toString(i + 1)),
                _serializeSubTransaction(
                    string.concat("quiesce_sub_tx_operator_", vm.toString(i + 1)), coreProxy, revokeOperatorCalldatas[i]
                )
            );
            subTxsInitialized = true;
        }
        require(subTxsInitialized, "Core already fully quiesced");

        string memory operatorRevocations = _buildOperatorRevocationsJson(activeOperators, configuredOperatorCount);

        string memory safeArgs = vm.serializeAddress("quiesce_safe_args", "to", multiSendAddress);
        safeArgs = vm.serializeString("quiesce_safe_args", "value", "0");
        safeArgs = vm.serializeUint("quiesce_safe_args", "operation", 1);
        safeArgs = vm.serializeString("quiesce_safe_args", "data", vm.toString(multiSendCalldata));

        string memory safe = vm.serializeAddress("quiesce_safe", "to", multiSendAddress);
        safe = vm.serializeString("quiesce_safe", "value", "0");
        safe = vm.serializeUint("quiesce_safe", "operation", 1);
        safe = vm.serializeString("quiesce_safe", "method", "multiSend(bytes)");
        safe = vm.serializeString("quiesce_safe", "calldata", vm.toString(multiSendCalldata));

        string memory root = vm.serializeString("quiesce_plan", "network", envName);
        root = vm.serializeString("quiesce_plan", "phase", "quiesce");
        root = vm.serializeUint("quiesce_plan", "chainId", block.chainid);
        root = vm.serializeAddress("quiesce_plan", "coreProxy", coreProxy);
        root = vm.serializeAddress("quiesce_plan", "ownerSafe", owner);
        root = vm.serializeString("quiesce_plan", "operatorRevocations", operatorRevocations);
        root = vm.serializeString("quiesce_plan", "sub_transactions", subTxs);
        root = vm.serializeString("quiesce_plan", "safe_args", safeArgs);
        root = vm.serializeString("quiesce_plan", "safe", safe);

        return root;
    }
}
