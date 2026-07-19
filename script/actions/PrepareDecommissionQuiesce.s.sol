// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {console} from "forge-std/console.sol";

/// @title PrepareDecommissionQuiesce
/// @notice Emits the exact Safe MultiSend payload for SIG-820 phase 1: pause Core and revoke configured operators.
contract PrepareDecommissionQuiesce is BaseScript {
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
        require(!core.paused(), "Core already paused; quiesce plan not needed");
        _requireOperatorsValid(operators);

        bytes memory pauseCalldata = abi.encodeCall(SignalsCore.pause, ());
        bytes[] memory revokeOperatorCalldatas = new bytes[](operators.length);
        bytes memory packedTransactions = _encodeMultiSendTx(coreProxy, pauseCalldata);
        for (uint256 i = 0; i < operators.length; i++) {
            revokeOperatorCalldatas[i] = abi.encodeCall(SignalsCore.setOperator, (operators[i], false));
            packedTransactions =
                bytes.concat(packedTransactions, _encodeMultiSendTx(coreProxy, revokeOperatorCalldatas[i]));
        }
        bytes memory multiSendCalldata = abi.encodeWithSignature("multiSend(bytes)", packedTransactions);

        string memory plan = _buildPlanJson(
            multiSendAddress, coreProxy, owner, operators, pauseCalldata, revokeOperatorCalldatas, multiSendCalldata
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
        vm.writeFile(string.concat(copyDir, "/04-arg-data-multiSendCalldata.txt"), vm.toString(multiSendCalldata));
        vm.writeFile(string.concat(copyDir, "/sub-tx-1-pause.txt"), vm.toString(pauseCalldata));
        uint256 nextSubTx = 2;
        if (operators.length == 0) {
            vm.writeFile(
                string.concat(copyDir, "/operator-revocations-skipped.txt"),
                "Skipped: config.operatorAllowlist is empty.\n"
            );
        } else {
            for (uint256 i = 0; i < operators.length; i++) {
                vm.writeFile(
                    string.concat(copyDir, "/sub-tx-", vm.toString(nextSubTx), "-setOperator-false.txt"),
                    string.concat(
                        "operator: ",
                        vm.toString(operators[i]),
                        "\ncalldata: ",
                        vm.toString(revokeOperatorCalldatas[i]),
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

    function _buildOperatorRevocationsJson(address[] memory operators) internal returns (string memory) {
        string memory operatorRevocations = vm.serializeUint("quiesce_operator_revocations", "count", operators.length);
        if (operators.length == 0) {
            operatorRevocations =
                vm.serializeString("quiesce_operator_revocations", "status", "skipped_no_operator_allowlist");
        } else {
            operatorRevocations = vm.serializeString("quiesce_operator_revocations", "status", "included");
            for (uint256 i = 0; i < operators.length; i++) {
                operatorRevocations = vm.serializeAddress(
                    "quiesce_operator_revocations", string.concat("operator", vm.toString(i + 1)), operators[i]
                );
            }
        }
        return operatorRevocations;
    }

    function _buildPlanJson(
        address multiSendAddress,
        address coreProxy,
        address owner,
        address[] memory operators,
        bytes memory pauseCalldata,
        bytes[] memory revokeOperatorCalldatas,
        bytes memory multiSendCalldata
    ) internal returns (string memory) {
        string memory subTxs = vm.serializeString(
            "quiesce_sub_transactions",
            "pause",
            _serializeSubTransaction("quiesce_sub_tx_pause", coreProxy, pauseCalldata)
        );
        if (operators.length == 0) {
            string memory skipped =
                vm.serializeString("quiesce_sub_tx_operator_revocations", "status", "skipped_no_operator_allowlist");
            subTxs = vm.serializeString("quiesce_sub_transactions", "operatorRevocations", skipped);
        } else {
            for (uint256 i = 0; i < operators.length; i++) {
                subTxs = vm.serializeString(
                    "quiesce_sub_transactions",
                    string.concat("setOperatorFalse", vm.toString(i + 1)),
                    _serializeSubTransaction(
                        string.concat("quiesce_sub_tx_operator_", vm.toString(i + 1)),
                        coreProxy,
                        revokeOperatorCalldatas[i]
                    )
                );
            }
        }

        string memory operatorRevocations = _buildOperatorRevocationsJson(operators);

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
