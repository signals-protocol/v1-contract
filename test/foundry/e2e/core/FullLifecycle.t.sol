// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title Full Lifecycle E2E Test
/// @notice 1 test: create market → trade → transfer NFT → settle → claim with ownership checks
contract FullLifecycleTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
    }

    function test_trades_settles_transfers_and_claims() public {
        address trader = sys.users[0];
        address receiver = sys.users[1];
        address coreAddress = address(sys.core);

        // Seed vault
        uint256 seedAmount = 20_000_000;
        sys.payment.mint(sys.owner, seedAmount);
        vm.startPrank(sys.owner);
        sys.payment.approve(coreAddress, seedAmount);
        sys.core.seedVault(seedAmount);
        vm.stopPrank();

        // Fund trader
        sys.payment.mint(trader, 50_000_000);
        vm.prank(trader);
        sys.payment.approve(coreAddress, type(uint256).max);

        // Create market
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 50);
        uint64 settlement = uint64(block.timestamp + 60);

        vm.prank(sys.owner);
        uint256 marketId = sys.core.createMarketUniform(
            0,
            4,
            1,
            start,
            end,
            settlement,
            4,
            WAD,
            address(sys.feePolicy)
        );

        // Open position
        uint128 quantity = 1_000;
        uint256 openCost = sys.core.calculateOpenCost(marketId, 1, 3, quantity);
        uint256 maxCost = openCost + 1_000_000;
        uint256 positionId = sys.position.nextId();
        vm.prank(trader);
        sys.core.openPosition(marketId, 1, 3, quantity, maxCost);

        // Transfer NFT to receiver
        vm.prank(trader);
        sys.position.transferFrom(trader, receiver, positionId);

        // Settle at tick 2 (winning for [1,3))
        SettlementHelper.settleMarket(vm, coreAddress, sys.owner, marketId, 2);

        // Process settlement chunks
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        // Claim too early should revert
        vm.prank(receiver);
        vm.expectPartialRevert(SE.ClaimTooEarly.selector);
        sys.core.claimPayout(positionId);

        // Advance past claim delay
        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        // Original trader cannot claim (no longer owner)
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, trader));
        sys.core.claimPayout(positionId);

        // Receiver claims successfully
        uint256 balanceBefore = sys.payment.balanceOf(receiver);
        vm.prank(receiver);
        sys.core.claimPayout(positionId);
        uint256 balanceAfter = sys.payment.balanceOf(receiver);
        assertGt(balanceAfter, balanceBefore);

        // Position is burned
        assertFalse(sys.position.exists(positionId));
    }
}
