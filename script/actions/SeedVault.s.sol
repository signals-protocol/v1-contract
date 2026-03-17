// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {console} from "forge-std/console.sol";

/// @title SeedVault — Approve payment token and seed vault
/// @notice Requires SEED_VAULT_AMOUNT_USD env var (human USD amount, 6 decimals)
contract SeedVault is BaseScript {
    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address paymentAddr = _contractAddr("PaymentToken");

        uint256 amount6 = vm.envUint("SEED_VAULT_AMOUNT_USD") * 1e6;
        require(amount6 > 0, "SEED_VAULT_AMOUNT_USD must be > 0");
        require(IERC20Metadata(paymentAddr).decimals() == 6, "Payment token must have 6 decimals");

        SignalsCore core = SignalsCore(coreProxy);
        if (core.isVaultSeeded()) {
            console.log("[seed-vault] vault already seeded; skipping");
            return;
        }

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        uint256 allowance = IERC20(paymentAddr).allowance(deployer, coreProxy);
        if (allowance < amount6) {
            IERC20(paymentAddr).approve(coreProxy, amount6);
        }

        core.seedVault(amount6);

        vm.stopBroadcast();

        console.log("[seed-vault] seeded %s (6 decimals)", amount6);
    }
}
