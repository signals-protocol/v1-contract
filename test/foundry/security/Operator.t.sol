// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/FullSystemDeployer.sol";
import "../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";
import {ISignalsCore} from "../../../contracts/interfaces/ISignalsCore.sol";
import {SeedData} from "../../../contracts/utils/SeedData.sol";

/// @title Operator Access Control Tests
/// @notice Foundry port of test/security/operator.security.spec.ts (18 tests)
contract OperatorSecurityTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal operator;
    address internal outsider;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(3600, 3600);

        operator = makeAddr("operator");
        outsider = makeAddr("outsider");
        vm.deal(operator, 1 ether);
        vm.deal(outsider, 1 ether);

        // Fund and approve
        sys.payment.mint(sys.owner, 1_000_000e6);
        sys.payment.mint(operator, 1_000_000e6);
        sys.payment.mint(outsider, 1_000_000e6);

        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(operator);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(outsider);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Seed vault
        vm.prank(sys.owner);
        sys.core.seedVault(100_000e6);
    }

    function _createMarketParams()
        internal
        view
        returns (
            int256 minTick,
            int256 maxTick,
            int256 tickSpacing,
            uint64 start,
            uint64 end,
            uint64 settlement,
            uint32 numBins,
            uint256 liquidityParameter
        )
    {
        uint64 now_ = uint64(block.timestamp);
        return (0, 4, 1, now_ - 100, now_ + 10000, now_ + 10100, 4, WAD);
    }

    function _deploySeedData(uint32 numBins) internal returns (address) {
        uint256[] memory factors = uniformFactors(numBins);
        bytes memory encoded;
        for (uint256 i = 0; i < factors.length; i++) {
            encoded = abi.encodePacked(encoded, factors[i]);
        }
        SeedData sd = new SeedData(encoded);
        return address(sd);
    }

    // ============================================================
    // Operator allowlist management
    // ============================================================

    function test_owner_manages_operator_allowlist_zero_address_rejected() public {
        // Outsider cannot add operator
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, outsider)); // OwnableUnauthorizedAccount
        sys.core.setOperator(operator, true);

        // Zero address rejected
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.ZeroAddress.selector));
        sys.core.setOperator(address(0), true);

        // Owner adds operator
        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit ISignalsCore.OperatorUpdated(operator, true);
        sys.core.setOperator(operator, true);
        assertTrue(sys.core.operators(operator));

        // Owner removes operator
        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit ISignalsCore.OperatorUpdated(operator, false);
        sys.core.setOperator(operator, false);
        assertFalse(sys.core.operators(operator));
    }

    // ============================================================
    // createMarket gating
    // ============================================================

    function test_gates_createMarket_to_owner_operator() public {
        (
            int256 minTick,
            int256 maxTick,
            int256 tickSpacing,
            uint64 start,
            uint64 end,
            uint64 settlement,
            uint32 numBins,
            uint256 liqParam
        ) = _createMarketParams();
        address seed = _deploySeedData(numBins);

        // Outsider rejected
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.createMarket(
            minTick,
            maxTick,
            tickSpacing,
            start,
            end,
            settlement,
            numBins,
            liqParam,
            address(sys.feePolicy),
            seed
        );

        // Owner succeeds
        vm.prank(sys.owner);
        sys.core.createMarket(
            minTick,
            maxTick,
            tickSpacing,
            start,
            end,
            settlement,
            numBins,
            liqParam,
            address(sys.feePolicy),
            seed
        );

        // Add operator
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // Operator succeeds (need new seed and new params for unique market)
        address seed2 = _deploySeedData(numBins);
        uint64 now_ = uint64(block.timestamp);
        vm.prank(operator);
        sys.core.createMarket(
            minTick,
            maxTick,
            tickSpacing,
            now_ - 99,
            now_ + 10001,
            now_ + 10101,
            numBins,
            liqParam,
            address(sys.feePolicy),
            seed2
        );
    }

    // ============================================================
    // seedNextChunks gating
    // ============================================================

    function test_gates_seedNextChunks_to_owner_operator() public {
        (
            int256 minTick,
            int256 maxTick,
            int256 tickSpacing,
            uint64 start,
            uint64 end,
            uint64 settlement,
            uint32 numBins,
            uint256 liqParam
        ) = _createMarketParams();
        address seed = _deploySeedData(numBins);

        // Create market (not seeded yet - createMarket doesn't seed chunks)
        vm.prank(sys.owner);
        uint256 marketId = sys.core.createMarket(
            minTick,
            maxTick,
            tickSpacing,
            start,
            end,
            settlement,
            numBins,
            liqParam,
            address(sys.feePolicy),
            seed
        );

        // Outsider rejected
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.seedNextChunks(marketId, 1);

        // Add operator
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // Operator succeeds
        vm.prank(operator);
        sys.core.seedNextChunks(marketId, 1);

        // Owner seeds remaining
        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 3);
    }

    // ============================================================
    // Settlement ops gating
    // ============================================================

    function test_gates_settlement_ops_to_owner_operator() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // finalizePrimarySettlement - outsider rejected
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.finalizePrimarySettlement(999);

        // operator gets past access control, fails on MarketNotFound
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.finalizePrimarySettlement(999);

        // owner same
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.finalizePrimarySettlement(999);

        // markSettlementFailed
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.markSettlementFailed(999);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.markSettlementFailed(999);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.markSettlementFailed(999);

        // requestSettlementChunks
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.requestSettlementChunks(999, 1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.requestSettlementChunks(999, 1);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.requestSettlementChunks(999, 1);
    }

    // ============================================================
    // finalizeSecondarySettlement is owner-only
    // ============================================================

    function test_finalizeSecondarySettlement_is_owner_only_rejects_operator() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // operator rejected with OwnableUnauthorizedAccount
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, operator));
        sys.core.finalizeSecondarySettlement(999, 100);

        // owner passes access control but fails on MarketNotFound
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.finalizeSecondarySettlement(999, 100);
    }

    // ============================================================
    // Pause tests
    // ============================================================

    function test_pause_operator_can_pause_unpause_is_owner_only() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // Outsider cannot pause
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.pause();

        // Operator can pause
        vm.prank(operator);
        sys.core.pause();

        // Operator cannot unpause
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, operator));
        sys.core.unpause();

        // Owner can unpause
        vm.prank(sys.owner);
        sys.core.unpause();
    }

    function test_pause_blocks_requestDeposit_but_allows_claimWithdraw() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 batch1 = currentBatchId + 1;
        uint64 batch2 = currentBatchId + 2;

        // Create a withdrawal claim for batch2 (withdrawalLagBatches=1)
        vm.prank(sys.owner);
        sys.core.requestWithdraw(1000e18);

        vm.startPrank(sys.owner);
        sys.core.harnessSetBatchMarketState(batch1, 1, 1);
        sys.core.harnessSetBatchMarketState(batch2, 1, 1);
        vm.stopPrank();

        vm.warp(batchEndTimestamp(batch1) + 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batch1);

        vm.warp(batchEndTimestamp(batch2) + 1);
        vm.prank(sys.owner);
        sys.core.processDailyBatch(batch2);

        vm.prank(operator);
        sys.core.pause();

        // requestDeposit is guarded by whenNotPaused
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xd93c0665))); // EnforcedPause()
        sys.core.requestDeposit(10e6);

        // claimWithdraw must remain available during pause
        vm.prank(sys.owner);
        sys.core.claimWithdraw(0);

        vm.prank(sys.owner);
        sys.core.unpause();
    }

    function test_pause_while_paused_only_owner_can_processDailyBatch() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        uint64 currentBatchId = sys.core.getCurrentBatchId();
        uint64 nextBatchId = currentBatchId + 1;

        vm.prank(operator);
        sys.core.pause();

        // Operator rejected while paused
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, operator));
        sys.core.processDailyBatch(nextBatchId);

        // Owner can process while paused
        vm.prank(sys.owner);
        sys.core.processDailyBatch(nextBatchId);

        assertEq(sys.core.getCurrentBatchId(), nextBatchId);

        vm.prank(sys.owner);
        sys.core.unpause();
    }

    function test_pause_while_paused_only_owner_can_markSettlementFailed() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // Create a market
        uint64 now_ = uint64(block.timestamp);
        vm.prank(sys.owner);
        uint256 marketId = sys.core.createMarketUniform(
            0,
            4,
            1,
            now_ - 100,
            now_ + 10000,
            now_ + 10100,
            4,
            WAD,
            address(sys.feePolicy)
        );

        vm.prank(operator);
        sys.core.pause();

        // Operator rejected while paused
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, operator));
        sys.core.markSettlementFailed(marketId);

        // Owner can mark failed (warp past settlement submit window)
        uint64 submitWindow = 3600;
        uint64 failedAt = now_ + 10100 + submitWindow + 1;
        vm.warp(failedAt);

        vm.prank(sys.owner);
        sys.core.markSettlementFailed(marketId);

        vm.prank(sys.owner);
        sys.core.unpause();
    }

    // ============================================================
    // updateMarketTiming is owner-only
    // ============================================================

    function test_updateMarketTiming_is_owner_only_rejects_operator() public {
        vm.prank(sys.owner);
        sys.core.setOperator(operator, true);

        // operator rejected with OwnableUnauthorizedAccount
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, operator));
        sys.core.updateMarketTiming(999, 100, 200, 300);

        // owner passes access control but fails on MarketNotFound
        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotFound.selector, 999));
        sys.core.updateMarketTiming(999, 100, 200, 300);
    }
}
