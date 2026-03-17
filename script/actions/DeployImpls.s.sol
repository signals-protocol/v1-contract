// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {SignalsPosition} from "../../contracts/position/SignalsPosition.sol";
import {SignalsLPShare} from "../../contracts/tokens/SignalsLPShare.sol";

/// @title DeployImpls — Deploy 3 implementation contracts
contract DeployImpls is BaseScript {
    function run() external {
        _enforceChainId();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        SignalsCore coreImpl = new SignalsCore();
        SignalsPosition positionImpl = new SignalsPosition();
        SignalsLPShare lpShareImpl = new SignalsLPShare();

        vm.stopBroadcast();

        // Write output for post-deploy.ts
        string memory contracts = vm.serializeAddress("deploy-impls", "SignalsCoreImplementation", address(coreImpl));
        contracts = vm.serializeAddress("deploy-impls", "SignalsPositionImplementation", address(positionImpl));
        contracts = vm.serializeAddress("deploy-impls", "SignalsLPShareImplementation", address(lpShareImpl));

        string memory root = vm.serializeString("root", "action", "deploy-impls");
        root = vm.serializeAddress("root", "deployer", vm.addr(deployerKey));
        root = vm.serializeString("root", "contracts", contracts);

        _writeOutput("deploy-impls", root);
    }
}
