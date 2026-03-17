// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {console} from "forge-std/console.sol";

/// @title SetTimeline — Set settlement timeline from env JSON config
contract SetTimeline is BaseScript {
    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        SignalsCore core = SignalsCore(coreProxy);

        uint256 submitWindow = _tryConfigUint("settlementSubmitWindow");
        uint256 pendingOps = _tryConfigUint("pendingOpsWindow");
        uint256 claimDelay = _tryConfigUint("settlementFinalizeDeadline");

        require(submitWindow > 0 && pendingOps > 0 && claimDelay > 0, "Missing timeline config");
        require(claimDelay == submitWindow + pendingOps, "Invalid timeline invariant");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        core.setSettlementTimeline(uint64(submitWindow), uint64(pendingOps), uint64(claimDelay));

        vm.stopBroadcast();

        console.log("[set-timeline] submit=%s ops=%s claim=%s", submitWindow, pendingOps, claimDelay);
    }
}
