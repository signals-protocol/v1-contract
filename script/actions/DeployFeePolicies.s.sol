// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {NullFeePolicy} from "../../contracts/fees/NullFeePolicy.sol";
import {
    PercentFeePolicy10bps,
    PercentFeePolicy50bps,
    PercentFeePolicy100bps,
    PercentFeePolicy200bps
} from "../../contracts/fees/PercentFeePolicies.sol";

/// @title DeployFeePolicies — Deploy 5 fee policy contracts
contract DeployFeePolicies is BaseScript {
    function run() external {
        _enforceChainId();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        NullFeePolicy nullFee = new NullFeePolicy();
        PercentFeePolicy10bps fee10 = new PercentFeePolicy10bps();
        PercentFeePolicy50bps fee50 = new PercentFeePolicy50bps();
        PercentFeePolicy100bps fee100 = new PercentFeePolicy100bps();
        PercentFeePolicy200bps fee200 = new PercentFeePolicy200bps();

        vm.stopBroadcast();

        // Write output for post-deploy.ts
        string memory out = vm.serializeAddress("deploy-fee-policies", "FeePolicyNull", address(nullFee));
        out = vm.serializeAddress("deploy-fee-policies", "FeePolicy10bps", address(fee10));
        out = vm.serializeAddress("deploy-fee-policies", "FeePolicy50bps", address(fee50));
        out = vm.serializeAddress("deploy-fee-policies", "FeePolicy100bps", address(fee100));
        out = vm.serializeAddress("deploy-fee-policies", "FeePolicy200bps", address(fee200));

        string memory root = vm.serializeString("root", "action", "deploy-fee-policies");
        root = vm.serializeAddress("root", "deployer", vm.addr(deployerKey));
        root = vm.serializeString("root", "contracts", out);

        _writeOutput("deploy-fee-policies", root);
    }
}
