// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {ISignalsPosition} from "../../../../contracts/interfaces/ISignalsPosition.sol";

/// @title Storage Tests for SignalsPosition
/// @notice 7 tests covering position data storage and counter management
contract PositionStorageTest is FullSystemDeployer {
    FullSystem internal sys;

    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
        alice = sys.users[0];
        bob = sys.users[1];
    }

    // ================================================================
    // Position Data Storage
    // ================================================================

    function test_stores_position_data_correctly() public {
        uint256 marketId = 1;
        int256 lowerTick = 100;
        int256 upperTick = 200;
        uint128 quantity = 1000;

        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, marketId, lowerTick, upperTick, quantity);

        ISignalsPosition.Position memory pos = sys.position.getPosition(1);

        assertEq(pos.marketId, marketId);
        assertEq(pos.lowerTick, lowerTick);
        assertEq(pos.upperTick, upperTick);
        assertEq(pos.quantity, quantity);
        assertGt(pos.createdAt, 0);
    }

    function test_handles_multiple_positions_with_different_data() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(alice, 1, 100, 200, 1000);
        sys.position.mintPosition(bob, 1, 300, 400, 2000);
        vm.stopPrank();

        ISignalsPosition.Position memory alicePos = sys.position.getPosition(1);
        ISignalsPosition.Position memory bobPos = sys.position.getPosition(2);

        assertEq(alicePos.lowerTick, 100);
        assertEq(alicePos.upperTick, 200);
        assertEq(alicePos.quantity, 1000);

        assertEq(bobPos.lowerTick, 300);
        assertEq(bobPos.upperTick, 400);
        assertEq(bobPos.quantity, 2000);
    }

    function test_getPosition_reverts_for_nonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, 999));
        sys.position.getPosition(999);
    }

    function test_updateQuantity_stores_new_value() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);
        sys.position.updateQuantity(1, 2500);
        vm.stopPrank();

        assertEq(sys.position.getPosition(1).quantity, 2500);
    }

    function test_updateQuantity_preserves_other_fields() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(alice, 5, 100, 200, 1000);
        vm.stopPrank();

        ISignalsPosition.Position memory before = sys.position.getPosition(1);

        vm.prank(address(sys.core));
        sys.position.updateQuantity(1, 5000);

        ISignalsPosition.Position memory after_ = sys.position.getPosition(1);

        assertEq(after_.marketId, before.marketId);
        assertEq(after_.lowerTick, before.lowerTick);
        assertEq(after_.upperTick, before.upperTick);
        assertEq(after_.createdAt, before.createdAt);
        assertEq(after_.quantity, 5000);
    }

    // ================================================================
    // Counter Management
    // ================================================================

    function test_increments_token_ids() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);
        sys.position.mintPosition(alice, 1, 10, 20, 1000);
        sys.position.mintPosition(alice, 1, 20, 30, 1000);
        vm.stopPrank();

        assertEq(sys.position.ownerOf(1), alice);
        assertEq(sys.position.ownerOf(2), alice);
        assertEq(sys.position.ownerOf(3), alice);
        assertEq(sys.position.nextId(), 4);
    }

    function test_does_not_reuse_burned_ids() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);
        sys.position.burn(1);
        sys.position.mintPosition(alice, 1, 10, 20, 1000);
        vm.stopPrank();

        // Token ID 1 is burned, new token is ID 2
        assertFalse(sys.position.exists(1));
        assertEq(sys.position.ownerOf(2), alice);
    }
}
