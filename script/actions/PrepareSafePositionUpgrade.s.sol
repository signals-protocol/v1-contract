// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsPosition} from "../../contracts/position/SignalsPosition.sol";
import {console} from "forge-std/console.sol";

/// @title PrepareSafePositionUpgrade — Deploy new Position impl, output Safe TX calldata
/// @notice Env vars:
///   ENV          — dev|prod (required)
///   PRIVATE_KEY  — deployer key (required)
contract PrepareSafePositionUpgrade is BaseScript {
    function run() external {
        _enforceChainId();

        address positionProxy = _contractAddr("SignalsPositionProxy");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("[prepare-safe-position-upgrade] deployer=%s", deployer);
        console.log("[prepare-safe-position-upgrade] positionProxy=%s", positionProxy);

        vm.startBroadcast(deployerKey);

        // 1. Deploy new SignalsPosition implementation
        SignalsPosition positionImpl = new SignalsPosition();
        address newImpl = address(positionImpl);
        console.log("[prepare-safe-position-upgrade] new implementation=%s", newImpl);

        vm.stopBroadcast();

        // 2. Encode calldata — upgradeToAndCall(newImpl, "0x") (no initialization data)
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, "");

        // 3. Write plan JSON
        string memory deployed = vm.serializeAddress("deployed", "SignalsPositionImplementation", newImpl);

        string memory safeArgs = vm.serializeAddress("safe_args", "newImplementation", newImpl);
        safeArgs = vm.serializeString("safe_args", "data", "0x");

        string memory safe = vm.serializeAddress("safe", "to", positionProxy);
        safe = vm.serializeString("safe", "value", "0");
        safe = vm.serializeString("safe", "method", "upgradeToAndCall(address newImplementation, bytes data)");
        safe = vm.serializeString("safe", "args", safeArgs);
        safe = vm.serializeString("safe", "calldata", vm.toString(upgradeCalldata));

        string memory plan = vm.serializeString("plan", "network", envName);
        plan = vm.serializeUint("plan", "chainId", block.chainid);
        plan = vm.serializeAddress("plan", "deployer", deployer);
        plan = vm.serializeAddress("plan", "positionProxy", positionProxy);
        plan = vm.serializeString("plan", "deployed", deployed);
        plan = vm.serializeString("plan", "safe", safe);

        string memory releasesDir = string.concat("releases/", envName);
        vm.createDir(releasesDir, true);
        string memory planPath = string.concat(releasesDir, "/safe-position-upgrade-plan.json");
        vm.writeFile(planPath, plan);
        console.log("[prepare-safe-position-upgrade] plan saved: %s", planPath);

        // 4. Write copy files for Safe manual execution
        string memory copyDir = string.concat(releasesDir, "/safe-position-upgrade-copy");
        vm.createDir(copyDir, true);
        vm.writeFile(string.concat(copyDir, "/01-to.txt"), vm.toString(positionProxy));
        vm.writeFile(string.concat(copyDir, "/02-value.txt"), "0");
        vm.writeFile(
            string.concat(copyDir, "/03-method.txt"),
            "upgradeToAndCall(address newImplementation, bytes data)"
        );
        vm.writeFile(string.concat(copyDir, "/04-arg-newImplementation.txt"), vm.toString(newImpl));
        vm.writeFile(string.concat(copyDir, "/05-arg-data.txt"), "0x");
        vm.writeFile(string.concat(copyDir, "/06-calldata-upgradeToAndCall.txt"), vm.toString(upgradeCalldata));
        console.log("[prepare-safe-position-upgrade] copy files: %s", copyDir);

        // 5. Print Safe manual execution instructions
        console.log("==============================================");
        console.log("Safe Manual Execution [OWNER ONLY]");
        console.log("==============================================");
        console.log("1) Safe -> New Transaction -> Contract Interaction");
        console.log("2) To = Position proxy, Value = 0");
        console.log("3) Paste ABI, choose upgradeToAndCall");
        console.log("4) Fill args or paste calldata in Data field");

        // 6. Write script output for post-deploy.ts
        string memory contracts = vm.serializeAddress(
            "prepare-safe-position-upgrade",
            "SignalsPositionImplementation",
            newImpl
        );

        string memory root = vm.serializeString("root", "action", "prepare-safe-position-upgrade");
        root = vm.serializeAddress("root", "deployer", deployer);
        root = vm.serializeString("root", "contracts", contracts);

        _writeOutput("prepare-safe-position-upgrade", root);
    }
}
