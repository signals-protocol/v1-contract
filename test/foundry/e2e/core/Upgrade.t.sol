// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../../../contracts/testonly/SignalsCoreV2.sol";
import "../../../../contracts/testonly/SignalsPositionV2.sol";

/// @title UUPS Upgrade E2E Test
/// @notice 1 test: upgrade core and position proxies without losing state
contract UpgradeTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
    }

    function test_upgrades_core_and_position_without_losing_state() public {
        address trader = sys.users[0];
        address coreAddress = address(sys.core);
        address positionAddress = address(sys.position);

        // Fund trader
        sys.payment.mint(trader, 50_000_000);
        vm.prank(trader);
        sys.payment.approve(coreAddress, type(uint256).max);

        // Create market and open position
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 50);
        uint64 settlement = uint64(block.timestamp + 60);

        vm.prank(sys.owner);
        uint256 marketId = sys.core.createMarketUniform(0, 4, 1, start, end, settlement, 4, WAD, address(sys.feePolicy));

        uint128 quantity = 1_000;
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, quantity);
        uint256 positionId = sys.position.nextId();
        vm.prank(trader);
        sys.core.openPosition(marketId, 1, 3, quantity, cost + 1_000_000);

        // Upgrade core
        SignalsCoreV2 coreV2Impl = new SignalsCoreV2();
        vm.prank(sys.owner);
        sys.core.upgradeToAndCall(address(coreV2Impl), "");
        SignalsCoreV2 coreV2 = SignalsCoreV2(coreAddress);
        assertEq(coreV2.version(), "v2");

        // Upgrade position
        SignalsPositionV2 positionV2Impl = new SignalsPositionV2();
        vm.prank(sys.owner);
        sys.position.upgradeToAndCall(address(positionV2Impl), "");
        SignalsPositionV2 positionV2 = SignalsPositionV2(positionAddress);
        assertEq(positionV2.version(), "v2");

        // State preserved
        assertTrue(sys.position.exists(positionId));
    }
}
