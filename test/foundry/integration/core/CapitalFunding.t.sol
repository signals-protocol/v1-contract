// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {SignalsCoreStorage} from "../../../../contracts/core/SignalsCoreStorage.sol";

/// @title Capital Funding Integration Tests
/// @notice Tests token flows and free balance calculations (10 tests from capitalFunding.spec.ts)
contract CapitalFundingTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal user;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
        user = sys.users[0];

        // Fund owner and user with USDC
        sys.payment.mint(sys.owner, 100_000e6);
        sys.payment.mint(user, 100_000e6);

        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    function test_allows_permissionless_backstop_funding() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit SignalsCoreStorage.BackstopFunded(user, 500e6, 500e18);
        sys.core.fundBackstop(500e6);

        (uint256 backstopNav, ) = sys.core.getCapitalStack();
        assertEq(backstopNav, 500e18);
        assertEq(sys.payment.balanceOf(address(sys.core)), 500e6);
    }

    function test_allows_permissionless_treasury_funding() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit SignalsCoreStorage.TreasuryFunded(user, 250e6, 250e18);
        sys.core.fundTreasury(250e6);

        (, uint256 treasuryNav) = sys.core.getCapitalStack();
        assertEq(treasuryNav, 250e18);
        assertEq(sys.payment.balanceOf(address(sys.core)), 250e6);
    }

    function test_restricts_backstop_withdrawal_to_owner() public {
        vm.prank(sys.owner);
        sys.core.fundBackstop(100e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, user)); // OwnableUnauthorizedAccount
        sys.core.withdrawBackstop(10e6);
    }

    function test_withdraws_backstop_to_owner_and_updates_NAV() public {
        vm.prank(sys.owner);
        sys.core.fundBackstop(1000e6);

        uint256 ownerBefore = sys.payment.balanceOf(sys.owner);

        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit SignalsCoreStorage.BackstopWithdrawn(sys.owner, 400e6, 600e18);
        sys.core.withdrawBackstop(400e6);

        (uint256 backstopNav, ) = sys.core.getCapitalStack();
        assertEq(backstopNav, 600e18);
        assertEq(sys.payment.balanceOf(sys.owner), ownerBefore + 400e6);
    }

    function test_withdraws_treasury_to_owner_and_updates_NAV() public {
        vm.prank(sys.owner);
        sys.core.fundTreasury(700e6);

        uint256 ownerBefore = sys.payment.balanceOf(sys.owner);

        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit SignalsCoreStorage.TreasuryWithdrawn(sys.owner, 200e6, 500e18);
        sys.core.withdrawTreasury(200e6);

        (, uint256 treasuryNav) = sys.core.getCapitalStack();
        assertEq(treasuryNav, 500e18);
        assertEq(sys.payment.balanceOf(sys.owner), ownerBefore + 200e6);
    }

    function test_reverts_when_withdrawal_exceeds_free_balance() public {
        vm.prank(sys.owner);
        sys.core.fundBackstop(1000e6);

        // Set reserves to lock 900 USDC, leaving only 100 free
        vm.prank(sys.owner);
        sys.core.harnessSetReserves(0, 0, 900e6);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InsufficientFreeBalance.selector, 200e6, 100e6));
        sys.core.withdrawBackstop(200e6);
    }

    // Additional tests from the TS spec that are implicit

    function test_backstop_funding_transfers_tokens() public {
        uint256 coreBefore = sys.payment.balanceOf(address(sys.core));
        uint256 userBefore = sys.payment.balanceOf(user);

        vm.prank(user);
        sys.core.fundBackstop(500e6);

        assertEq(sys.payment.balanceOf(address(sys.core)), coreBefore + 500e6);
        assertEq(sys.payment.balanceOf(user), userBefore - 500e6);
    }

    function test_treasury_funding_transfers_tokens() public {
        uint256 coreBefore = sys.payment.balanceOf(address(sys.core));
        uint256 userBefore = sys.payment.balanceOf(user);

        vm.prank(user);
        sys.core.fundTreasury(500e6);

        assertEq(sys.payment.balanceOf(address(sys.core)), coreBefore + 500e6);
        assertEq(sys.payment.balanceOf(user), userBefore - 500e6);
    }

    function test_restricts_treasury_withdrawal_to_owner() public {
        vm.prank(sys.owner);
        sys.core.fundTreasury(100e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, user)); // OwnableUnauthorizedAccount
        sys.core.withdrawTreasury(10e6);
    }

    function test_multiple_funding_rounds_accumulate() public {
        vm.startPrank(sys.owner);
        sys.core.fundBackstop(500e6);
        sys.core.fundBackstop(300e6);
        vm.stopPrank();

        (uint256 backstopNav, ) = sys.core.getCapitalStack();
        assertEq(backstopNav, 800e18);
    }
}
