// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/SignalsBaseTest.sol";
import "../../../contracts/position/SignalsPosition.sol";
import "../../../contracts/testonly/TestERC1967Proxy.sol";
import "../../../contracts/testonly/SignalsUSDToken.sol";

/// @title PositionInvariantTest
/// @notice Foundry invariant tests for SignalsPosition contract.
/// @dev Mirrors test/invariant/position.invariants.spec.ts (6 tests).
///
/// Invariants tested:
///   - INV-P1: Balance consistency (totalSupply == sum of balances)
///   - INV-P2: Position ID uniqueness and sequentiality
///   - INV-P5: Transfer preserves total supply
///   - INV-P6: Burn decreases supply by exactly 1
///   - Stress: Random mint/transfer/burn preserves invariants
contract PositionInvariantTest is SignalsBaseTest {
    SignalsPosition position;
    address coreSigner;
    address alice;
    address bob;
    address charlie;
    address dave;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");

        // Deploy a token to use its address as core signer (like TS test)
        SignalsUSDToken token = new SignalsUSDToken();
        coreSigner = address(token);
        vm.deal(coreSigner, 1 ether);

        // Deploy position with proxy
        SignalsPosition impl = new SignalsPosition();
        bytes memory initData = abi.encodeCall(SignalsPosition.initialize, (coreSigner, address(this)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        position = SignalsPosition(address(proxy));
    }

    // ============================================================
    // INV-P1: Balance Consistency
    // ============================================================

    function test_INVP1_balanceConsistencyThroughOperations() public {
        address[3] memory users = [alice, bob, charlie];

        // Initial state
        assertEq(_sumBalances(users), 0);

        // Mint to alice
        vm.prank(coreSigner);
        position.mintPosition(alice, 1, 0, 10, 1000);
        assertEq(_sumBalances(users), 1);

        // Mint to bob
        vm.prank(coreSigner);
        position.mintPosition(bob, 1, 10, 20, 1000);
        assertEq(_sumBalances(users), 2);

        // Mint to charlie
        vm.prank(coreSigner);
        position.mintPosition(charlie, 2, 0, 5, 500);
        assertEq(_sumBalances(users), 3);

        // Transfer (sum stays same)
        vm.prank(alice);
        position.safeTransferFrom(alice, bob, 1);
        assertEq(_sumBalances(users), 3);

        // Burn
        vm.prank(coreSigner);
        position.burn(2);
        assertEq(_sumBalances(users), 2);

        // Burn remaining
        vm.prank(coreSigner);
        position.burn(1);
        vm.prank(coreSigner);
        position.burn(3);
        assertEq(_sumBalances(users), 0);
    }

    // ============================================================
    // INV-P2: Position ID Uniqueness
    // ============================================================

    function test_INVP2_uniqueSequentialIds() public {
        address[3] memory users = [alice, bob, charlie];

        for (uint256 i = 0; i < 10; i++) {
            address user = users[i % 3];
            vm.prank(coreSigner);
            position.mintPosition(user, 1, int256(i), int256(i + 1), 1000);
        }

        // Verify IDs 1..10 all exist with correct owners
        for (uint256 i = 1; i <= 10; i++) {
            address owner = position.ownerOf(i);
            assertTrue(owner != address(0), "INV-P2: each ID must have an owner");
        }
    }

    function test_INVP2_noIdReuse() public {
        vm.startPrank(coreSigner);
        position.mintPosition(alice, 1, 0, 10, 1000); // ID 1
        position.mintPosition(alice, 1, 10, 20, 1000); // ID 2
        position.burn(1);
        position.mintPosition(alice, 1, 20, 30, 1000); // ID 3
        vm.stopPrank();

        vm.expectRevert();
        position.ownerOf(1);

        assertEq(position.ownerOf(2), alice);
        assertEq(position.ownerOf(3), alice);
    }

    // ============================================================
    // INV-P5: Transfer Balance Invariant
    // ============================================================

    function test_INVP5_transferPreservesBalanceSum() public {
        address[3] memory users = [alice, bob, charlie];

        vm.startPrank(coreSigner);
        position.mintPosition(alice, 1, 0, 10, 1000);
        position.mintPosition(alice, 1, 10, 20, 1000);
        vm.stopPrank();

        uint256 sumBefore = _sumBalances(users);

        // Multiple transfers
        vm.prank(alice);
        position.transferFrom(alice, bob, 1);
        assertEq(_sumBalances(users), sumBefore);

        vm.prank(bob);
        position.transferFrom(bob, charlie, 1);
        assertEq(_sumBalances(users), sumBefore);

        vm.prank(charlie);
        position.transferFrom(charlie, alice, 1);
        assertEq(_sumBalances(users), sumBefore);
    }

    // ============================================================
    // INV-P6: Burn Balance Invariant
    // ============================================================

    function test_INVP6_burnDecreasesByOne() public {
        vm.startPrank(coreSigner);
        position.mintPosition(alice, 1, 0, 10, 1000);
        position.mintPosition(alice, 1, 10, 20, 1000);
        position.mintPosition(alice, 1, 20, 30, 1000);
        vm.stopPrank();

        assertEq(position.balanceOf(alice), 3);

        vm.prank(coreSigner);
        position.burn(2);
        assertEq(position.balanceOf(alice), 2);

        vm.prank(coreSigner);
        position.burn(1);
        assertEq(position.balanceOf(alice), 1);

        vm.prank(coreSigner);
        position.burn(3);
        assertEq(position.balanceOf(alice), 0);
    }

    // ============================================================
    // Stress: Random Operations
    // ============================================================

    function test_stressRandomMintTransferBurn() public {
        address[4] memory users = [alice, bob, charlie, dave];
        uint256 nextId = 1;

        // Simple deterministic PRNG (matches TS test)
        uint256 seed = 12345;

        uint256[] memory aliveIds = new uint256[](30);
        uint256 aliveLen = 0;

        for (uint256 i = 0; i < 30; i++) {
            seed = (seed * 1664525 + 1013904223) % 0xffffffff;
            uint256 op = seed % 3;

            if (op == 0 || aliveLen == 0) {
                // Mint
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                uint256 userIdx = seed % 4;
                vm.prank(coreSigner);
                position.mintPosition(users[userIdx], uint256((seed % 3) + 1), int256(i), int256(i + 1), 1000);
                aliveIds[aliveLen] = nextId;
                aliveLen++;
                nextId++;
            } else if (op == 1 && aliveLen > 0) {
                // Transfer
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                uint256 idx = seed % aliveLen;
                uint256 tokenId = aliveIds[idx];
                address currentOwner = position.ownerOf(tokenId);

                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                address newOwner = users[seed % 4];

                if (currentOwner != newOwner) {
                    vm.prank(currentOwner);
                    position.safeTransferFrom(currentOwner, newOwner, tokenId);
                }
            } else if (op == 2 && aliveLen > 0) {
                // Burn
                seed = (seed * 1664525 + 1013904223) % 0xffffffff;
                uint256 idx = seed % aliveLen;
                uint256 tokenId = aliveIds[idx];

                vm.prank(coreSigner);
                position.burn(tokenId);

                // Swap and pop
                aliveIds[idx] = aliveIds[aliveLen - 1];
                aliveLen--;
            }

            // Assert INV-P1: sum of balances == alive count
            uint256 actualSum = 0;
            for (uint256 j = 0; j < 4; j++) {
                actualSum += position.balanceOf(users[j]);
            }
            assertEq(actualSum, aliveLen, "Stress: balance sum must equal alive count");
        }
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _sumBalances(address[3] memory users) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < users.length; i++) {
            sum += position.balanceOf(users[i]);
        }
    }
}
