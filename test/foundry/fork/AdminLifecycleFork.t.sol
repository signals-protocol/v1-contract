// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkProtocolTest.sol";
import "../../../contracts/errors/SignalsErrors.sol";

/// @title AdminLifecycleForkTest
/// @notice Deterministic fork coverage for admin controls, pause semantics, and capital-stack flows.
contract AdminLifecycleForkTest is ForkProtocolTest {
    function test_risk_config_can_gate_market_creation_without_touching_position_exposure_logic() public {
        vm.prank(ownerSafe);
        core.setRiskConfig(1, WAD, true);

        (uint256 lambda, uint256 kDrawdown, bool enforceAlpha) = core.getRiskConfig();
        assertEq(lambda, 1, "lambda not updated");
        assertEq(kDrawdown, WAD, "kDrawdown not updated");
        assertTrue(enforceAlpha, "alpha enforcement not enabled");

        uint64 targetBatch = _targetBatchAfter(uint64(block.timestamp + 120));
        uint64 settlementTimestamp = _batchStartTimestamp(targetBatch) + 600;
        if (settlementTimestamp < block.timestamp + 120) {
            settlementTimestamp = uint64(block.timestamp + 120);
            targetBatch = _toBatchId(settlementTimestamp);
        }

        uint64 endTimestamp = settlementTimestamp - 30;
        uint64 startTimestamp = endTimestamp - 30;
        address seedData = _deployUniformSeedData(4);

        vm.prank(ownerSafe);
        vm.expectPartialRevert(SignalsErrors.AlphaExceedsLimit.selector);
        core.createMarket(
            0,
            4,
            1,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            4,
            WAD,
            _defaultFeePolicy(),
            seedData
        );

        vm.prank(ownerSafe);
        core.setRiskConfig(0.3e18, WAD, false);

        (lambda, kDrawdown, enforceAlpha) = core.getRiskConfig();
        assertEq(lambda, 0.3e18, "lambda reset mismatch");
        assertEq(kDrawdown, WAD, "kDrawdown reset mismatch");
        assertFalse(enforceAlpha, "alpha enforcement still enabled");

        vm.prank(ownerSafe);
        uint256 marketId = core.createMarket(
            0,
            4,
            1,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            4,
            WAD,
            _defaultFeePolicy(),
            seedData
        );

        vm.prank(ownerSafe);
        core.seedNextChunks(marketId, 4);
        assertTrue(core.getMarket(marketId).isSeeded, "market did not seed after risk config update");
    }

    function test_operator_paths_pause_owner_fallback_and_claim_invariant_hold_on_fork() public {
        address operator = _ensureForkOperator();

        uint64 targetBatch = _targetBatchAfter(uint64(block.timestamp + 120));
        uint64 settlementTimestamp = _batchStartTimestamp(targetBatch) + 600;
        if (settlementTimestamp < block.timestamp + 120) {
            settlementTimestamp = uint64(block.timestamp + 120);
            targetBatch = _toBatchId(settlementTimestamp);
        }

        address seedData = _deployUniformSeedData(4);
        uint64 endTimestamp = settlementTimestamp - 30;
        uint64 startTimestamp = endTimestamp - 30;

        vm.prank(operator);
        uint256 marketId = core.createMarket(
            0,
            4,
            1,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            4,
            WAD,
            _defaultFeePolicy(),
            seedData
        );

        vm.prank(operator);
        core.seedNextChunks(marketId, 2);
        assertFalse(core.getMarket(marketId).isSeeded, "market seeded too early");

        vm.prank(operator);
        core.seedNextChunks(marketId, 2);
        assertTrue(core.getMarket(marketId).isSeeded, "operator could not finish seeding");

        vm.prank(ownerSafe);
        core.updateMarketTiming(marketId, startTimestamp + 1, endTimestamp + 1, settlementTimestamp + 1);
        assertEq(core.getMarket(marketId).settlementTimestamp, settlementTimestamp + 1, "owner timing update failed");

        address lp = makeAddr("pausedLp");
        _fundAndApprove(lp, 1_000_000_000);

        vm.prank(lp);
        uint64 depositRequestId = core.requestDeposit(300_000_000);

        uint64 depositBatch = core.getCurrentBatchId() + 1;
        _processBatchesThrough(depositBatch);

        vm.prank(lp);
        uint256 mintedShares = core.claimDeposit(depositRequestId);

        uint256 withdrawShares = mintedShares / 2;
        vm.prank(lp);
        uint64 withdrawRequestId = core.requestWithdraw(withdrawShares);

        uint64 withdrawBatch = core.getCurrentBatchId() + core.getWithdrawalLagBatches() + 1;
        _processBatchesThrough(withdrawBatch);

        vm.prank(operator);
        core.pause();
        assertTrue(core.paused(), "operator pause failed");

        vm.prank(lp);
        vm.expectRevert();
        core.requestDeposit(10_000_000);

        uint64 nextBatch = core.getCurrentBatchId() + 1;
        uint64 batchEnd = _batchEndTimestamp(nextBatch);
        if (block.timestamp <= batchEnd) {
            vm.warp(uint256(batchEnd) + 1);
        }

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SignalsErrors.UnauthorizedCaller.selector, operator));
        core.processDailyBatch(nextBatch);

        vm.prank(ownerSafe);
        core.processDailyBatch(nextBatch);
        assertEq(core.getCurrentBatchId(), nextBatch, "owner could not process while paused");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SignalsErrors.UnauthorizedCaller.selector, operator));
        core.markSettlementFailed(999_999);

        vm.prank(ownerSafe);
        vm.expectRevert(abi.encodeWithSelector(SignalsErrors.MarketNotFound.selector, uint256(999_999)));
        core.markSettlementFailed(999_999);

        uint256 balanceBeforeClaim = payment.balanceOf(lp);
        vm.prank(lp);
        core.claimWithdraw(withdrawRequestId);
        assertGt(payment.balanceOf(lp), balanceBeforeClaim, "claimWithdraw blocked while paused");

        vm.prank(ownerSafe);
        core.unpause();
        assertFalse(core.paused(), "owner unpause failed");
    }

    function test_fee_waterfall_processing_updates_backstop_and_treasury_after_owner_config_change() public {
        vm.prank(ownerSafe);
        core.setFeeWaterfallConfig(0, 0, 0.5e18, 0.5e18);

        (uint256 backstopBefore, uint256 treasuryBefore) = core.getCapitalStack();

        uint64 targetBatch = _targetBatchAfter(uint64(block.timestamp + 120));
        uint256 marketId = _createUniformMarketForBatch(targetBatch);

        address trader = makeAddr("waterfallTrader");
        _fundAndApprove(trader, 100_000_000);

        uint128 losingQty = 4_000_000;
        uint256 maxCost = core.calculateOpenCost(marketId, 1, 2, losingQty) + 1_000_000;

        vm.prank(trader);
        core.openPosition(marketId, 1, 2, losingQty, maxCost);

        uint64 batchId = _secondarySettleAndSnapshot(marketId, 0, 8);
        _processBatchesThrough(batchId);

        (, uint256 ftot, , , , , bool processed) = core.getDailyPnl(batchId);
        (uint256 backstopAfter, uint256 treasuryAfter) = core.getCapitalStack();

        assertTrue(processed, "daily pnl not processed");
        assertGt(ftot, 0, "trade generated no fees");
        assertGt(backstopAfter, backstopBefore, "backstop did not receive fee share");
        assertGt(treasuryAfter, treasuryBefore, "treasury did not receive fee share");
    }

    function test_permissionless_funding_and_owner_withdrawals_adjust_capital_stack() public {
        address funder = makeAddr("capitalFunder");
        _fundAndApprove(funder, 100_000_000);

        (uint256 backstopBefore, uint256 treasuryBefore) = core.getCapitalStack();

        vm.prank(funder);
        core.fundBackstop(20_000_000);
        vm.prank(funder);
        core.fundTreasury(15_000_000);

        (uint256 backstopFunded, uint256 treasuryFunded) = core.getCapitalStack();
        assertEq(backstopFunded - backstopBefore, 20_000_000 * 1e12, "backstop funding mismatch");
        assertEq(treasuryFunded - treasuryBefore, 15_000_000 * 1e12, "treasury funding mismatch");

        uint256 ownerBalanceBefore = payment.balanceOf(ownerSafe);

        vm.prank(ownerSafe);
        core.withdrawBackstop(5_000_000);
        vm.prank(ownerSafe);
        core.withdrawTreasury(7_000_000);

        (uint256 backstopAfter, uint256 treasuryAfter) = core.getCapitalStack();
        assertEq(backstopFunded - backstopAfter, 5_000_000 * 1e12, "backstop withdrawal mismatch");
        assertEq(treasuryFunded - treasuryAfter, 7_000_000 * 1e12, "treasury withdrawal mismatch");
        assertEq(payment.balanceOf(ownerSafe) - ownerBalanceBefore, 12_000_000, "owner did not receive withdrawals");
    }
}
