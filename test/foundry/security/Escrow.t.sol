// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/FullSystemDeployer.sol";
import "../base/VaultHelper.sol";
import "../base/SettlementHelper.sol";
import "../base/RedstoneHelper.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";

/// @title Escrow Security Tests
/// @notice Foundry port of test/security/escrow.security.spec.ts (5 tests)
/// @dev Free balance protection, settlement tick clamping
contract EscrowSecurityTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal user1;
    address internal user2;

    function setUp() public override {
        super.setUp();
        // Use wide submit/ops windows matching TS tests (3600 each)
        sys = deployFullSystem(3600, 3600);

        user1 = sys.users[0];
        user2 = sys.users[1];

        // Fund users
        sys.payment.mint(sys.owner, 1_000_000e6);
        sys.payment.mint(user1, 1_000_000e6);
        sys.payment.mint(user2, 1_000_000e6);

        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user1);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user2);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Seed vault
        vm.prank(sys.owner);
        sys.core.seedVault(100_000e6);
    }

    // ============================================================
    // Free Balance Protection
    // ============================================================

    function test_trade_proceeds_cannot_use_pending_deposits() public {
        // User1 requests deposit (creates pending deposit)
        vm.prank(user1);
        sys.core.requestDeposit(10_000e6);

        // Create a market for user2 to trade
        uint64 now_ = uint64(block.timestamp);
        vm.prank(sys.owner);
        uint256 mktId = sys.core
            .createMarketUniform(0, 100, 1, now_ - 100, now_ + 10000, now_ + 10100, 100, WAD, address(sys.feePolicy));

        // User2 opens a position
        vm.prank(user2);
        sys.core.openPosition(mktId, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);

        // User2 closes position - should succeed but not drain pending deposits
        vm.prank(user2);
        sys.core.closePosition(1, 0);

        // Core should still have at least the pending deposit amount
        uint256 balanceAfter = sys.payment.balanceOf(address(sys.core));
        assertGe(balanceAfter, 10_000e6);
    }

    // ============================================================
    // Settlement Tick Clamp
    // ============================================================

    function test_settlement_at_maxTick_boundary_clamps_to_last_valid_tick() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 settlementTs = now_ + 1000;

        vm.prank(sys.owner);
        uint256 mktId = sys.core
            .createMarketUniform(0, 100, 1, now_ - 100, now_ + 500, settlementTs, 100, WAD, address(sys.feePolicy));

        // User opens position at upper boundary
        vm.prank(user1);
        sys.core.openPosition(mktId, 95, 100, uint128(SMALL_QUANTITY), 1_000e6);

        // Submit settlement at exactly maxTick (100) - should clamp to 99
        // Use SettlementHelper for full Redstone-based flow
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, mktId, 100);

        // Verify settlement tick is clamped
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(mktId);
        assertEq(market.settlementTick, 99);
    }

    function test_settlement_above_maxTick_clamps_correctly() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 settlementTs = now_ + 1000;

        vm.prank(sys.owner);
        uint256 mktId = sys.core
            .createMarketUniform(0, 100, 1, now_ - 100, now_ + 500, settlementTs, 100, WAD, address(sys.feePolicy));

        vm.prank(user1);
        sys.core.openPosition(mktId, 90, 100, uint128(SMALL_QUANTITY), 1_000e6);

        // Submit settlement way above maxTick
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, mktId, 500);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(mktId);
        assertEq(market.settlementTick, 99);
    }

    function test_settlement_below_minTick_clamps_to_minTick() public {
        uint64 now_ = uint64(block.timestamp);
        uint64 settlementTs = now_ + 1000;

        // Create market with minTick = 50
        vm.prank(sys.owner);
        uint256 mktId = sys.core
            .createMarketUniform(50, 100, 1, now_ - 100, now_ + 500, settlementTs, 50, WAD, address(sys.feePolicy));

        vm.prank(user1);
        sys.core.openPosition(mktId, 50, 60, uint128(SMALL_QUANTITY), 1_000e6);

        // Submit settlement below minTick (price = 10, but minTick = 50)
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, mktId, 10);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(mktId);
        assertEq(market.settlementTick, 50);
    }
}
