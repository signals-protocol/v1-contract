// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/TradeModuleDeployer.sol";

/// @notice Smoke tests proving the TradeModule deployer works correctly.
contract TradeModuleBasicTest is TradeModuleDeployer {
    TradeModuleSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployMinimalTradeSystem();
    }

    function test_setUp_deploysSystem() public view {
        // Core contracts deployed
        assertTrue(address(sys.payment) != address(0), "payment deployed");
        assertTrue(address(sys.position) != address(0), "position deployed");
        assertTrue(address(sys.feePolicy) != address(0), "feePolicy deployed");
        assertTrue(address(sys.tradeModule) != address(0), "tradeModule deployed");
        assertTrue(address(sys.core) != address(0), "core deployed");

        // Owner and users set
        assertTrue(sys.owner != address(0), "owner set");
        assertEq(sys.users.length, 1, "1 user");

        // User funded
        assertEq(sys.payment.balanceOf(sys.users[0]), 100_000e6, "user funded");
    }

    function test_openPosition_basic() public {
        address user = sys.users[0];
        uint256 marketId = 1;

        // Calculate cost first
        uint256 cost = sys.core.calculateOpenCost(marketId, 0, 2, 1000);
        assertTrue(cost > 0, "cost > 0");

        // Open position
        vm.prank(user);
        uint256 positionId = sys.core.openPosition(marketId, 0, 2, 1000, cost);
        assertEq(positionId, 1, "first position id = 1");
    }

    function test_openPosition_revertsOnZeroQuantity() public {
        address user = sys.users[0];
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(1, 0, 2, 0, type(uint256).max);
    }
}
