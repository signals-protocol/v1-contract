// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/FullSystemDeployer.sol";
import "../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";
import {SeedData} from "../../../contracts/utils/SeedData.sol";

/// @title Batch Processing Security Tests
/// @notice Foundry port of test/security/batch.security.spec.ts (8 tests)
/// @dev Future batch prevention, access control, sequence enforcement, double processing
contract BatchSecurityTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal user1;
    address internal user2;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(3600, 3600);

        user1 = sys.users[0];
        user2 = sys.users[1];

        // Fund and approve
        sys.payment.mint(sys.owner, 1_000_000e6);
        sys.payment.mint(user1, 1_000_000e6);
        sys.payment.mint(user2, 1_000_000e6);

        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user1);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(user2);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Seed vault (with withdrawalLagBatches=1 but using 0 in TS; override via harness)
        vm.prank(sys.owner);
        sys.core.seedVault(100_000e6);

        // Set withdrawalLagBatches to 0 to match TS fixture
        vm.prank(sys.owner);
        sys.core.harnessSetWithdrawalLagBatches(0);
    }

    // ============================================================
    // Batch Timing & Access
    // ============================================================

    function test_allows_processing_batch_even_before_its_time_period_ends() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 nextBatchId = currentBatchId + 1;

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(nextBatchId, 1, 1);

        vm.prank(sys.owner);
        sys.core.processDailyBatch(nextBatchId);
    }

    function test_allows_processing_batch_with_no_assigned_markets() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 nextBatchId = currentBatchId + 1;

        vm.warp(batchEndTimestamp(nextBatchId) + 1);

        uint256 navBefore = sys.core.getVaultNav();
        uint256 sharesBefore = sys.core.getVaultShares();

        vm.prank(sys.owner);
        sys.core.processDailyBatch(nextBatchId);

        assertEq(sys.core.getCurrentBatchId(), nextBatchId);
        assertEq(sys.core.getVaultNav(), navBefore);
        assertEq(sys.core.getVaultShares(), sharesBefore);
    }

    function test_processing_empty_batch_blocks_future_market_creation_for_that_batch() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 nextBatchId = currentBatchId + 1;

        // Process the next batch without any markets
        vm.prank(sys.owner);
        sys.core.processDailyBatch(nextBatchId);

        // Try to create market for that batch - should revert
        uint64 t0 = batchStartTimestamp(nextBatchId) + 100;
        uint64 t1 = t0 + 200;
        uint64 tSet = t1;

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchAlreadyProcessed.selector, nextBatchId));
        sys.core.createMarketUniform(0, 4, 1, t0, t1, tSet, 4, WAD, address(sys.feePolicy));
    }

    function test_updateMarketTiming_cannot_move_market_into_processed_batch() public {
        uint64 base = sys.core.getCurrentBatchId();
        uint64 batch1 = base + 1;
        uint64 batch2 = base + 2;

        // Create a market for batch2
        uint64 t0 = batchStartTimestamp(batch2) + 100;
        uint64 t1 = t0 + 200;
        uint64 tSet = t1;
        vm.prank(sys.owner);
        sys.core.createMarketUniform(0, 4, 1, t0, t1, tSet, 4, WAD, address(sys.feePolicy));

        // Process batch1 empty
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batch1);

        // Attempt to move the market into batch1 (already processed)
        uint64 t0b = batchStartTimestamp(batch1) + 100;
        uint64 t1b = t0b + 200;
        uint64 tSetb = t1b;
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchAlreadyProcessed.selector, batch1));
        sys.core.updateMarketTiming(1, t0b, t1b, tSetb);
    }

    function test_allows_owner_or_operator_rejects_non_operator() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 nextBatchId = currentBatchId + 1;

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(nextBatchId, 1, 1);

        // Non-operator rejected
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, user2));
        sys.core.processDailyBatch(nextBatchId);

        // Add user1 as operator
        vm.prank(sys.owner);
        sys.core.setOperator(user1, true);

        // Operator succeeds
        vm.prank(user1);
        sys.core.processDailyBatch(nextBatchId);
    }

    // ============================================================
    // Batch Sequence Enforcement
    // ============================================================

    function test_reverts_processing_out_of_sequence_batch() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 farFutureBatchId = currentBatchId + 5;

        vm.warp(batchEndTimestamp(farFutureBatchId) + 1);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotReady.selector, farFutureBatchId));
        sys.core.processDailyBatch(farFutureBatchId);
    }

    function test_processes_batches_sequentially() public {
        uint64 startBatchId = sys.core.getCurrentBatchId();

        for (uint64 i = 1; i <= 3; i++) {
            uint64 batchId = startBatchId + i;
            vm.warp(batchEndTimestamp(batchId) + 1);

            vm.prank(sys.owner);
            sys.core.harnessSetBatchMarketState(batchId, 1, 1);

            vm.prank(sys.owner);
            sys.core.processDailyBatch(batchId);

            assertEq(sys.core.getCurrentBatchId(), batchId);
        }
    }

    // ============================================================
    // Double Processing Prevention
    // ============================================================

    function test_reverts_processing_same_batch_twice() public {
        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 nextBatchId = currentBatchId + 1;

        vm.warp(batchEndTimestamp(nextBatchId) + 1);

        vm.prank(sys.owner);
        sys.core.harnessSetBatchMarketState(nextBatchId, 1, 1);

        vm.prank(sys.owner);
        sys.core.processDailyBatch(nextBatchId);

        // Try to process again
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BatchNotReady.selector, nextBatchId));
        sys.core.processDailyBatch(nextBatchId);
    }
}
