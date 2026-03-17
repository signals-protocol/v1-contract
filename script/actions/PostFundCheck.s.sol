// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {console} from "forge-std/console.sol";

/// @title PostFundCheck — Read-only post-funding verification
/// @notice Verifies vault is seeded and backstop is funded
contract PostFundCheck is BaseScript {
    function run() external view {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        SignalsCore core = SignalsCore(coreProxy);

        bool seeded = core.isVaultSeeded();
        require(seeded, "Vault is not seeded");

        (uint256 backstopNav, uint256 treasuryNav) = core.getCapitalStack();
        require(backstopNav > 0, "Backstop NAV is zero");

        console.log("[post-fund-check] seeded=%s backstop=%s treasury=%s", seeded, backstopNav, treasuryNav);
    }
}
