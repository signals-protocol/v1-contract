// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Upgrades, Options, UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SignalsPosition} from "../../contracts/position/SignalsPosition.sol";
import {SignalsUSDToken} from "../../contracts/testonly/SignalsUSDToken.sol";

/// @notice Verify that openzeppelin-foundry-upgrades works with our UUPS + delegatecall architecture.
contract UpgradesIntegrationTest is Test {
    // ── Test 1: Deploy UUPS proxy (SignalsPosition) ──────────────────────
    function test_deployUUPSProxy_SignalsPosition() public {
        // SignalsPosition.initialize requires _core with code, deploy a stub
        SignalsUSDToken coreStub = new SignalsUSDToken();
        address owner = address(this);

        bytes memory initData = abi.encodeCall(SignalsPosition.initialize, (address(coreStub), owner));
        address proxy = Upgrades.deployUUPSProxy("SignalsPosition.sol", initData);

        // Proxy is functional
        assertTrue(proxy != address(0), "proxy deployed");
        assertTrue(proxy.code.length > 0, "proxy has code");

        // Implementation address is readable
        address impl = Upgrades.getImplementationAddress(proxy);
        assertTrue(impl != address(0), "impl address non-zero");
        assertTrue(impl != proxy, "impl differs from proxy");

        // Proxy delegates correctly — check ERC721 name set by initialize
        SignalsPosition position = SignalsPosition(proxy);
        assertEq(position.name(), "Signals Position");
        assertEq(position.symbol(), "SIGP");
    }

    // ── Test 2: Validate delegatecall contract (SignalsCore) ─────────────
    function test_validateImplementation_SignalsCore() public {
        Options memory opts;
        opts.unsafeAllow = "delegatecall";

        // Validates upgrade safety without deploying — no need for complex InitParams
        Upgrades.validateImplementation("SignalsCore.sol", opts);
    }

    // ── Test 3: UnsafeUpgrades alternative (no FFI) ──────────────────────
    function test_unsafeUpgrades_deployUUPSProxy() public {
        // Deploy implementation directly
        SignalsPosition impl = new SignalsPosition();

        // Deploy stub for core address requirement
        SignalsUSDToken coreStub = new SignalsUSDToken();
        address owner = address(this);

        bytes memory initData = abi.encodeCall(SignalsPosition.initialize, (address(coreStub), owner));
        address proxy = UnsafeUpgrades.deployUUPSProxy(address(impl), initData);

        // Verify proxy works
        assertTrue(proxy != address(0), "proxy deployed");
        address readImpl = UnsafeUpgrades.getImplementationAddress(proxy);
        assertEq(readImpl, address(impl), "impl matches deployed");

        // Proxy delegates correctly
        SignalsPosition position = SignalsPosition(proxy);
        assertEq(position.name(), "Signals Position");
    }
}
