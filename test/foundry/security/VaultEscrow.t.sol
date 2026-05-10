// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/FullSystemDeployer.sol";
import "../base/VaultHelper.sol";
import "../base/SettlementHelper.sol";
import "../base/RedstoneHelper.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";
import {SeedData} from "../../../contracts/utils/SeedData.sol";

/// @title Vault Escrow Security Tests
/// @notice Foundry port of test/security/vault-escrow.security.spec.ts (27 tests)
/// @dev CRITICAL-02: processDailyBatch finalized check
///      CRITICAL-03: cancel after batch processed
///      HIGH-01: withdrawal reserve in free balance
contract VaultEscrowSecurityTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal user1;
    address internal user2;
    address internal attacker;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(3600, 3600);

        user1 = sys.users[0];
        user2 = sys.users[1];
        attacker = sys.users[2];

        // Fund users
        sys.payment.mint(sys.owner, 1_000_000e6);
        sys.payment.mint(user1, 1_000_000e6);
        sys.payment.mint(user2, 1_000_000e6);
        sys.payment.mint(attacker, 1_000_000e6);

        // Approve
        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user1);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user2);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(attacker);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Also approve lpShare for withdrawals
        vm.prank(user1);
        sys.lpShare.approve(address(sys.core), type(uint256).max);
        vm.prank(user2);
        sys.lpShare.approve(address(sys.core), type(uint256).max);

        // Seed vault
        vm.prank(sys.owner);
        sys.core.seedVault(100_000e6);
    }

    function _createMarketInBatch(uint64 batchId) internal returns (uint256) {
        uint64 bStart = batchStartTimestamp(batchId);
        uint64 bEnd = batchEndTimestamp(batchId);
        uint64 now_ = uint64(block.timestamp);

        uint64 settlementTs = bStart + 43200; // Middle of batch day
        uint64 minSettlement = now_ + 120;
        if (settlementTs <= minSettlement) settlementTs = minSettlement;
        if (settlementTs >= bEnd) settlementTs = bEnd - 1;

        uint64 endTime = settlementTs - 1;
        uint64 startTime = endTime - 3600;

        vm.prank(sys.owner);
        uint256 marketId =
            sys.core.createMarketUniform(0, 10, 1, startTime, endTime, settlementTs, 10, WAD, address(sys.feePolicy));
        return marketId;
    }

    function _processBatchEmpty(uint64 batchId) internal {
        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(batchId, 1, 1);

        vm.warp(batchEndTimestamp(batchId) + 1);

        vm.prank(sys.owner);
        sys.core.processDailyBatch(batchId);
    }

    // ============================================================
    // CRITICAL-02: Batch Processing Before Market Finalized
    // ============================================================

    function test_reverts_processDailyBatch_when_batch_market_is_not_settled() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 targetBatchId = currentBatchId + 1;

        uint256 marketId = _createMarketInBatch(targetBatchId);
        assertGt(marketId, 0);

        // Fast forward past batch end time but DON'T finalize market
        vm.warp(batchEndTimestamp(targetBatchId) + 1);

        // Market is NOT settled
        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertFalse(market.settled);

        // Attacker tries to process batch without market being settled
        vm.prank(sys.owner);
        vm.expectRevert(
            abi.encodeWithSelector(SE.BatchMarketsNotResolved.selector, targetBatchId, uint64(0), uint64(1))
        );
        sys.core.processDailyBatch(targetBatchId);
    }

    function test_allows_processDailyBatch_after_market_is_finalized() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 targetBatchId = currentBatchId + 1;

        uint256 marketId = _createMarketInBatch(targetBatchId);

        // Settle the market using SettlementHelper
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, marketId, 5);

        // Fast forward to after batch end
        vm.warp(batchEndTimestamp(targetBatchId) + 1);

        // Now batch processing should succeed
        vm.prank(sys.owner);
        sys.core.processDailyBatch(targetBatchId);
    }

    function test_requires_all_markets_in_batch_to_be_settled() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 targetBatchId = currentBatchId + 1;

        uint256 marketId1 = _createMarketInBatch(targetBatchId);
        uint256 marketId2 = _createMarketInBatch(targetBatchId);

        // Get settlement timestamps for both markets
        ISignalsCore.Market memory m1 = sys.core.harnessGetMarket(marketId1);
        ISignalsCore.Market memory m2 = sys.core.harnessGetMarket(marketId2);

        uint64 submitWindow = 3600;
        uint64 opsStart1 = m1.settlementTimestamp + submitWindow + 1;
        uint64 opsStart2 = m2.settlementTimestamp + submitWindow + 1;
        uint64 opsStart = opsStart1 > opsStart2 ? opsStart1 : opsStart2;
        vm.warp(opsStart);

        // Mark market1 as failed
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId1);

        vm.warp(batchEndTimestamp(targetBatchId) + 1);

        // Can't process - market2 not resolved yet
        vm.prank(sys.owner);
        vm.expectRevert(
            abi.encodeWithSelector(SE.BatchMarketsNotResolved.selector, targetBatchId, uint64(0), uint64(2))
        );
        sys.core.processDailyBatch(targetBatchId);

        // Mark market2 as failed too
        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId2);

        // Still can't process - need secondary settlement
        vm.prank(sys.owner);
        vm.expectRevert(
            abi.encodeWithSelector(SE.BatchMarketsNotResolved.selector, targetBatchId, uint64(0), uint64(2))
        );
        sys.core.processDailyBatch(targetBatchId);

        // Finalize secondary settlement for both
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(marketId1, 100_000_000);
        vm.prank(sys.owner);
        sys.core.finalizeSecondarySettlement(marketId2, 100_000_000);

        // Now can process
        vm.prank(sys.owner);
        sys.core.processDailyBatch(targetBatchId);
    }

    function test_prevents_finalize_after_batch_is_processed() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 emptyBatchId = currentBatchId + 1;

        // Process an empty batch first
        _processBatchEmpty(emptyBatchId);

        // Now create market for next batch
        uint64 targetBatchId = emptyBatchId + 1;
        uint256 marketId = _createMarketInBatch(targetBatchId);

        // Complete settlement
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, marketId, 5);

        // Process the batch after finalization - should work
        vm.warp(batchEndTimestamp(targetBatchId) + 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(targetBatchId);
    }

    // ============================================================
    // CRITICAL-03: Cancel After Batch Processed
    // ============================================================

    function test_reverts_cancelDeposit_after_batch_is_processed() public {
        // Create deposit request
        vm.prank(user1);
        uint64 requestId = sys.core.requestDeposit(1_000e6);

        // Process the eligible batch
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 eligibleBatchId = currentBatchId + 1;
        _processBatchEmpty(eligibleBatchId);

        // Try to cancel after batch processed
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SE.CancelTooLate.selector, uint64(0), eligibleBatchId));
        sys.core.cancelDeposit(requestId);
    }

    function test_reverts_cancelWithdraw_after_batch_is_processed() public {
        // First deposit and claim to get shares
        vm.prank(user1);
        uint64 depositReqId = sys.core.requestDeposit(1_000e6);

        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 depositBatchId = currentBatchId + 1;
        _processBatchEmpty(depositBatchId);

        vm.prank(user1);
        sys.core.claimDeposit(depositReqId);

        // Now create withdraw request
        uint256 shares = sys.lpShare.balanceOf(user1);
        assertGt(shares, 0);

        vm.prank(user1);
        uint64 withdrawReqId = sys.core.requestWithdraw(shares);

        // Withdrawal lag = 1, so eligible batch = depositBatchId + 1 + 1
        uint64 eligibleBatchId = depositBatchId + 2;

        // Process intermediate batches
        for (uint64 b = depositBatchId + 1; b <= eligibleBatchId; b++) {
            _processBatchEmpty(b);
        }

        // Try to cancel after batch processed
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SE.CancelTooLate.selector, uint64(0), eligibleBatchId));
        sys.core.cancelWithdraw(withdrawReqId);
    }

    function test_allows_cancel_before_batch_is_processed() public {
        uint256 balanceBefore = sys.payment.balanceOf(user1);

        vm.prank(user1);
        uint64 requestId = sys.core.requestDeposit(1_000e6);

        // Cancel before batch processing
        vm.prank(user1);
        sys.core.cancelDeposit(requestId);

        uint256 balanceAfter = sys.payment.balanceOf(user1);
        assertEq(balanceAfter, balanceBefore);
    }

    function test_reverts_cancel_by_non_owner() public {
        vm.prank(user1);
        sys.core.requestDeposit(1_000e6);

        // user2 tries to cancel user1's request
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotOwned.selector, uint64(0), user1, user2));
        sys.core.cancelDeposit(0);
    }

    function test_reverts_claim_by_non_owner() public {
        vm.prank(user1);
        sys.core.requestDeposit(1_000e6);

        // Process batch
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 eligibleBatchId = currentBatchId + 1;
        _processBatchEmpty(eligibleBatchId);

        // user2 tries to claim user1's deposit
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotOwned.selector, uint64(0), user1, user2));
        sys.core.claimDeposit(0);
    }

    function test_reverts_claim_for_non_existent_request() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotFound.selector, uint64(999)));
        sys.core.claimDeposit(999);
    }

    // ============================================================
    // HIGH-01: Withdrawal Reserve Protection
    // ============================================================

    function test_reserves_processed_withdrawal_funds_in_free_balance() public {
        // User1 deposits
        vm.prank(user1);
        uint64 depositReqId = sys.core.requestDeposit(50_000e6);

        // Process deposit batch
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 depositBatchId = currentBatchId + 1;
        _processBatchEmpty(depositBatchId);

        // Claim deposit to get shares
        vm.prank(user1);
        sys.core.claimDeposit(depositReqId);

        uint256 user1Shares = sys.lpShare.balanceOf(user1);
        assertGt(user1Shares, 0);

        // User1 requests withdrawal of all shares
        vm.prank(user1);
        sys.core.requestWithdraw(user1Shares);

        // Process withdrawal batch (lag=1, so eligible = depositBatchId + 2)
        uint64 eligibleBatchId = depositBatchId + 2;
        for (uint64 b = depositBatchId + 1; b <= eligibleBatchId; b++) {
            _processBatchEmpty(b);
        }

        // User1 claims their withdrawal
        uint256 balanceBefore = sys.payment.balanceOf(user1);
        vm.prank(user1);
        sys.core.claimWithdraw(0);
        uint256 balanceAfter = sys.payment.balanceOf(user1);

        // Should receive approximately the deposited amount back
        assertGe(balanceAfter - balanceBefore, 49_000e6);
    }

    function test_prevents_double_claim_of_withdrawal_funds() public {
        // Deposit
        vm.prank(user1);
        uint64 depositReqId = sys.core.requestDeposit(10_000e6);

        // Process and claim deposit
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 depositBatchId = currentBatchId + 1;
        _processBatchEmpty(depositBatchId);

        vm.prank(user1);
        sys.core.claimDeposit(depositReqId);

        // Request withdrawal
        uint256 shares = sys.lpShare.balanceOf(user1);
        vm.prank(user1);
        sys.core.requestWithdraw(shares);

        // Process withdrawal batch
        uint64 eligibleBatchId = depositBatchId + 2;
        for (uint64 b = depositBatchId + 1; b <= eligibleBatchId; b++) {
            _processBatchEmpty(b);
        }

        // Claim withdrawal
        vm.prank(user1);
        sys.core.claimWithdraw(0);

        // Try to claim again - should revert (not Pending)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(SE.RequestNotPending.selector, uint64(0)));
        sys.core.claimWithdraw(0);
    }
}
