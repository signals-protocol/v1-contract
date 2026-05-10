// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import "../../../../contracts/modules/TradeModule.sol";
import "../../../../contracts/modules/MarketLifecycleModule.sol";

/// @title Module Hot-Swap E2E Test
/// @notice 1 test: swap trade/lifecycle modules mid-market, verify state consistency
contract ModuleSwapTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
    }

    function test_keeps_state_consistent_after_module_swap() public {
        address userA = sys.users[0];
        address userB = sys.users[1];
        address coreAddress = address(sys.core);

        // Seed vault
        uint256 seedAmount = 20_000_000;
        sys.payment.mint(sys.owner, seedAmount);
        vm.startPrank(sys.owner);
        sys.payment.approve(coreAddress, seedAmount);
        sys.core.seedVault(seedAmount);
        vm.stopPrank();

        // Fund users
        sys.payment.mint(userA, 50_000_000);
        sys.payment.mint(userB, 50_000_000);
        vm.prank(userA);
        sys.payment.approve(coreAddress, type(uint256).max);
        vm.prank(userB);
        sys.payment.approve(coreAddress, type(uint256).max);

        // Create market
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 50);
        uint64 settlement = uint64(block.timestamp + 60);

        vm.prank(sys.owner);
        uint256 marketId = sys.core.createMarketUniform(0, 4, 1, start, end, settlement, 4, WAD, address(sys.feePolicy));

        // User A opens position
        uint128 qtyA = 1_000;
        uint256 costA = sys.core.calculateOpenCost(marketId, 1, 3, qtyA);
        uint256 posA = sys.position.nextId();
        vm.prank(userA);
        sys.core.openPosition(marketId, 1, 3, qtyA, costA + 1_000_000);

        // Deploy new modules
        TradeModule newTrade = new TradeModule();
        MarketLifecycleModule newLifecycle = new MarketLifecycleModule();

        // Hot-swap modules
        vm.prank(sys.owner);
        sys.core
            .setModules(
                address(newTrade),
                address(newLifecycle),
                address(sys.riskModule),
                address(sys.vaultModule),
                address(sys.oracleModule)
            );

        // User B opens position with new modules
        uint128 qtyB = 2_000;
        uint256 costB = sys.core.calculateOpenCost(marketId, 1, 3, qtyB);
        uint256 posB = sys.position.nextId();
        vm.prank(userB);
        sys.core.openPosition(marketId, 1, 3, qtyB, costB + 1_000_000);

        // Settle at tick 2 (winning for [1,3))
        SettlementHelper.settleMarket(vm, coreAddress, sys.owner, marketId, 2);

        // Process settlement chunks
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        (,,, uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        // Both users claim
        vm.prank(userA);
        sys.core.claimPayout(posA);
        vm.prank(userB);
        sys.core.claimPayout(posB);

        assertFalse(sys.position.exists(posA));
        assertFalse(sys.position.exists(posB));
    }
}
