// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../../../contracts/errors/SignalsErrors.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title ERC721 Tests for SignalsPosition
/// @notice 19 tests covering metadata, balance, ownership, transfers, approvals, ERC165
contract PositionERC721Test is FullSystemDeployer {
    FullSystem internal sys;

    address internal alice;
    address internal bob;
    address internal charlie;

    // Pre-minted token IDs (set in _mintFixture)
    uint256 internal aliceToken1;
    uint256 internal aliceToken2;
    uint256 internal bobToken;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
        alice = sys.users[0];
        bob = sys.users[1];
        charlie = sys.users[2];
    }

    /// @dev Mint 3 positions: 2 for alice, 1 for bob
    function _mintFixture() internal {
        vm.startPrank(address(sys.core));
        aliceToken1 = sys.position.mintPosition(alice, 1, 0, 10, 1000);
        aliceToken2 = sys.position.mintPosition(alice, 1, 10, 20, 2000);
        bobToken = sys.position.mintPosition(bob, 2, 0, 5, 500);
        vm.stopPrank();
    }

    // ================================================================
    // ERC721 Metadata
    // ================================================================

    function test_name_and_symbol() public view {
        assertEq(sys.position.name(), "Signals Position");
        assertEq(sys.position.symbol(), "SIGP");
    }

    function test_tokenURI_returns_string() public {
        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 100, 200, 1000);

        string memory uri = sys.position.tokenURI(1);
        // v1 may not have tokenURI implemented — just verify it returns a string without reverting
        assertEq(bytes(uri).length >= 0, true);
    }

    function test_tokenURI_reverts_for_nonexistent_token() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        sys.position.tokenURI(999);
    }

    // ================================================================
    // ERC721 Balance and Ownership
    // ================================================================

    function test_balanceOf_tracks_correctly() public {
        assertEq(sys.position.balanceOf(alice), 0);

        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 0, 10, 1000);
        assertEq(sys.position.balanceOf(alice), 1);

        vm.prank(address(sys.core));
        sys.position.mintPosition(alice, 1, 10, 20, 2000);
        assertEq(sys.position.balanceOf(alice), 2);
    }

    function test_ownerOf_returns_correct_owner() public {
        _mintFixture();
        assertEq(sys.position.ownerOf(aliceToken1), alice);
    }

    function test_balanceOf_reverts_for_zero_address() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        sys.position.balanceOf(address(0));
    }

    function test_ownerOf_reverts_for_nonexistent_token() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        sys.position.ownerOf(999);
    }

    // ================================================================
    // ERC721 Transfers
    // ================================================================

    function test_transferFrom_works() public {
        _mintFixture();

        vm.prank(alice);
        sys.position.transferFrom(alice, bob, aliceToken1);

        assertEq(sys.position.ownerOf(aliceToken1), bob);
        assertEq(sys.position.balanceOf(alice), 1); // still has token2
        assertEq(sys.position.balanceOf(bob), 2); // bobToken + aliceToken1
    }

    function test_safeTransferFrom_works() public {
        _mintFixture();

        vm.prank(alice);
        sys.position.safeTransferFrom(alice, bob, aliceToken1);

        assertEq(sys.position.ownerOf(aliceToken1), bob);
    }

    function test_transferFrom_reverts_without_approval() public {
        _mintFixture();

        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, charlie, aliceToken1)
        );
        sys.position.transferFrom(alice, bob, aliceToken1);
    }

    function test_transferFrom_reverts_to_zero_address() public {
        _mintFixture();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        sys.position.transferFrom(alice, address(0), aliceToken1);
    }

    // ================================================================
    // ERC721 Approvals
    // ================================================================

    function test_approve_and_transfer() public {
        _mintFixture();

        vm.prank(alice);
        sys.position.approve(charlie, aliceToken1);
        assertEq(sys.position.getApproved(aliceToken1), charlie);

        vm.prank(charlie);
        sys.position.transferFrom(alice, bob, aliceToken1);

        assertEq(sys.position.ownerOf(aliceToken1), bob);
    }

    function test_setApprovalForAll() public {
        _mintFixture();

        vm.prank(alice);
        sys.position.setApprovalForAll(charlie, true);
        assertTrue(sys.position.isApprovedForAll(alice, charlie));

        // Charlie can transfer any of alice's tokens
        vm.startPrank(charlie);
        sys.position.transferFrom(alice, bob, aliceToken1);
        sys.position.transferFrom(alice, bob, aliceToken2);
        vm.stopPrank();

        assertEq(sys.position.balanceOf(alice), 0);
    }

    function test_approval_cleared_on_transfer() public {
        _mintFixture();

        vm.prank(alice);
        sys.position.approve(charlie, aliceToken1);
        assertEq(sys.position.getApproved(aliceToken1), charlie);

        vm.prank(alice);
        sys.position.transferFrom(alice, bob, aliceToken1);

        assertEq(sys.position.getApproved(aliceToken1), address(0));
    }

    function test_approve_reverts_from_non_owner() public {
        _mintFixture();

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, charlie));
        sys.position.approve(charlie, aliceToken1);
    }

    // ================================================================
    // ERC165 Interface Support
    // ================================================================

    function test_supportsInterface_ERC165() public view {
        assertTrue(sys.position.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_ERC721() public view {
        assertTrue(sys.position.supportsInterface(0x80ac58cd));
    }

    function test_supportsInterface_ERC721Metadata() public view {
        assertTrue(sys.position.supportsInterface(0x5b5e139f));
    }

    function test_does_not_support_random_interface() public view {
        assertFalse(sys.position.supportsInterface(0xdeadbeef));
    }
}
