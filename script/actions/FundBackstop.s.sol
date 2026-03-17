// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {console} from "forge-std/console.sol";

/// @title FundBackstop — Approve payment token and fund backstop
/// @notice Requires FUND_BACKSTOP_AMOUNT_USD env var (human USD amount, 6 decimals)
contract FundBackstop is BaseScript {
    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address paymentAddr = _contractAddr("PaymentToken");

        uint256 amount6 = vm.envUint("FUND_BACKSTOP_AMOUNT_USD") * 1e6;
        require(amount6 > 0, "FUND_BACKSTOP_AMOUNT_USD must be > 0");
        require(IERC20Metadata(paymentAddr).decimals() == 6, "Payment token must have 6 decimals");

        SignalsCore core = SignalsCore(coreProxy);
        (uint256 backstopNav, ) = core.getCapitalStack();
        if (backstopNav > 0) {
            console.log("[fund-backstop] backstop already funded (nav=%s); skipping", backstopNav);
            return;
        }

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        uint256 allowance = IERC20(paymentAddr).allowance(deployer, coreProxy);
        if (allowance < amount6) {
            IERC20(paymentAddr).approve(coreProxy, amount6);
        }

        core.fundBackstop(amount6);

        vm.stopBroadcast();

        console.log("[fund-backstop] funded %s (6 decimals)", amount6);
    }
}
