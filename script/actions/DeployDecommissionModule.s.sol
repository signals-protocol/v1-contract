// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {DecommissionModule} from "../../contracts/modules/DecommissionModule.sol";
import {console} from "forge-std/console.sol";

/// @title DeployDecommissionModule
/// @notice Deploys the SIG-820 decommission sweep module only. Owner-gated Core calls are Safe transactions.
/// @dev Writes script-output/deploy-decommission-module.json with the distinct DecommissionModule key.
contract DeployDecommissionModule is BaseScript {
    address internal constant PROD_CTUSD = 0x8D82c4E3c936C7B5724A382a9c5a4E6Eb7aB6d5D;

    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address paymentToken = address(SignalsCore(coreProxy).paymentToken());
        if (keccak256(bytes(envName)) == keccak256("prod")) {
            require(paymentToken == PROD_CTUSD, "prod Core paymentToken is not ctUSD");
        }
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("[deploy-decommission-module] deployer=%s", deployer);
        console.log("[deploy-decommission-module] coreProxy=%s", coreProxy);
        console.log("[deploy-decommission-module] paymentToken=%s", paymentToken);

        vm.startBroadcast(deployerKey);
        DecommissionModule module = new DecommissionModule(paymentToken);
        vm.stopBroadcast();

        address moduleAddress = address(module);
        console.log("[deploy-decommission-module] DecommissionModule=%s", moduleAddress);

        string memory contracts = vm.serializeAddress("deploy-decommission-module", "DecommissionModule", moduleAddress);

        string memory root = vm.serializeString("root", "action", "deploy-decommission-module");
        root = vm.serializeAddress("root", "deployer", deployer);
        root = vm.serializeString("root", "contracts", contracts);

        _writeOutput("deploy-decommission-module", root);
    }
}
