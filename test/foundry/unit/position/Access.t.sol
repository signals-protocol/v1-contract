// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title Access Control Tests for SignalsPosition
/// @notice 10 tests covering core-only authorization and owner-only functions
contract PositionAccessTest is FullSystemDeployer {
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
    // Core Authorization
    // ================================================================

    function test_exposes_core_address() public view {
        assertEq(sys.position.core(), address(sys.core));
    }

    // ================================================================
    // onlyCore Modifier
    // ================================================================

    function test_core_can_mint() public {
        vm.prank(address(sys.core));
        uint256 id = sys.position.mintPosition(alice, 1, 0, 10, 1000);
        assertEq(id, 1);
    }

    function test_mint_reverts_from_non_core() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, alice));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);
    }

    function test_core_can_updateQuantity() public {
        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);

        vm.prank(address(sys.core));
        sys.position.updateQuantity(1, 2000);

        assertEq(sys.position.getPosition(1).quantity, 2000);
    }

    function test_updateQuantity_reverts_from_non_core() public {
        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, alice));
        sys.position.updateQuantity(1, 2000);
    }

    function test_core_can_burn() public {
        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);

        vm.prank(address(sys.core));
        sys.position.burn(1);

        assertFalse(sys.position.exists(1));
    }

    function test_burn_reverts_from_non_core() public {
        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, alice));
        sys.position.burn(1);
    }

    // ================================================================
    // Owner-only Functions
    // ================================================================

    function test_owner_can_transfer_ownership() public {
        vm.prank(sys.owner);
        sys.position.transferOwnership(alice);
        assertEq(sys.position.owner(), alice);
    }

    function test_non_owner_cannot_transfer_ownership() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        sys.position.transferOwnership(alice);
    }

    // ================================================================
    // Edge Cases
    // ================================================================

    function test_operations_revert_after_burn() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);
        sys.position.burn(1);

        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, 1));
        sys.position.updateQuantity(1, 2000);
        vm.stopPrank();
    }
}
