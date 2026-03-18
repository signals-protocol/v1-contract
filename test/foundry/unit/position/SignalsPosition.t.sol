// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {ISignalsPosition} from "../../../../contracts/interfaces/ISignalsPosition.sol";

/// @title Combined Edge-Case Tests for SignalsPosition
/// @notice 5 tests covering core-only enforcement, edge cases, and combined flows
contract SignalsPositionTest is FullSystemDeployer {
    FullSystem internal sys;

    address internal user;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
        user = sys.users[0];
    }

    /// @notice Full lifecycle: non-core mint reverts, core mints, zero-qty update reverts,
    ///         core updates, non-core burn reverts, core burns, getPosition reverts after burn
    function test_enforces_core_only_mint_burn_update() public {
        // Non-core cannot mint
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, user));
        sys.position.mintPosition(user, 1, 0, 1, 1_000);

        // Core can mint
        vm.prank(address(sys.core));
        sys.position.mintPosition(user, 1, 0, 1, 1_000);

        // Zero quantity update reverts
        vm.prank(address(sys.core));
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidQuantity.selector, uint128(0)));
        sys.position.updateQuantity(1, 0);

        // Core can update
        vm.prank(address(sys.core));
        sys.position.updateQuantity(1, 2_000);

        // Non-core cannot burn
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, user));
        sys.position.burn(1);

        // Core can burn
        vm.prank(address(sys.core));
        sys.position.burn(1);

        // After burn, getPosition reverts
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, 1));
        sys.position.getPosition(1);
    }

    /// @notice Burning a non-existent position reverts
    function test_burn_nonexistent_reverts() public {
        vm.prank(address(sys.core));
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, 999));
        sys.position.burn(999);
    }

    /// @notice Double burn reverts on the second call
    function test_double_burn_reverts() public {
        vm.startPrank(address(sys.core));
        sys.position.mintPosition(user, 1, 0, 1, 1_000);
        sys.position.burn(1);

        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, 1));
        sys.position.burn(1);
        vm.stopPrank();
    }

    /// @notice Maximum uint128 quantity can be stored and retrieved
    function test_max_quantity_value() public {
        uint128 maxQty = type(uint128).max;

        vm.prank(address(sys.core));
        sys.position.mintPosition(user, 1, 0, 1, maxQty);

        ISignalsPosition.Position memory pos = sys.position.getPosition(1);
        assertEq(pos.quantity, maxQty);
    }

    /// @notice Zero-based tick range [0, 1] is stored correctly
    function test_zero_based_tick_range() public {
        vm.prank(address(sys.core));
        sys.position.mintPosition(user, 1, 0, 1, 1_000);

        ISignalsPosition.Position memory pos = sys.position.getPosition(1);
        assertEq(pos.lowerTick, 0);
        assertEq(pos.upperTick, 1);
    }
}
