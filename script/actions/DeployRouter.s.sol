// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsRouter} from "../../contracts/router/SignalsRouter.sol";

contract DeployRouter is BaseScript {
    function run() external {
        _enforceChainId();

        address core = _contractAddr("SignalsCoreProxy");
        address position = _contractAddr("SignalsPositionProxy");
        address paymentToken = _contractAddr("PaymentToken");
        address satsumaSwapRouter = _tryContractAddr("SatsumaSwapRouter");
        address owner = _tryConfigAddr("owners.core");

        require(satsumaSwapRouter != address(0), "missing SatsumaSwapRouter");
        require(owner != address(0), "missing config.owners.core");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        SignalsRouter router = new SignalsRouter(core, position, paymentToken, satsumaSwapRouter, address(0), owner);
        vm.stopBroadcast();

        string memory contractsJson = vm.serializeAddress("deploy-router", "SignalsRouter", address(router));
        string memory root = vm.serializeString("root", "action", "deploy-router");
        root = vm.serializeAddress("root", "deployer", deployer);
        root = vm.serializeString("root", "contracts", contractsJson);

        _writeOutput("deploy-router", root);
    }
}
