// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkProtocolTest.sol";

/// @title CoreTradeForkTest
/// @notice Deterministic fork coverage for created-market payout flows.
contract CoreTradeForkTest is ForkProtocolTest {
    uint128 internal constant QUANTITY = 5_000_000;

    function test_sponsored_position_claim_splits_principal_and_profit_after_batch_processing() public {
        uint64 targetBatch = _targetBatchAfter(uint64(block.timestamp + 120));
        uint256 marketId = _createUniformMarketForBatch(targetBatch);

        address sponsor = makeAddr("sponsor");
        address beneficiary = makeAddr("beneficiary");
        _fundAndApprove(sponsor, 100_000_000);

        uint256 maxCost = core.calculateOpenCost(marketId, 1, 3, QUANTITY) + 1_000_000;
        uint256 positionId = position.nextId();

        vm.prank(sponsor);
        core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, maxCost);

        uint256 sponsoredCost = core.getSponsoredCost(positionId);
        assertGt(sponsoredCost, 0, "sponsored cost not recorded");
        assertEq(core.getSponsorAddress(positionId), sponsor, "sponsor address mismatch");

        uint64 batchId = _secondarySettleAndSnapshot(marketId, 2_000_000, 8);
        _processBatchesThrough(batchId);

        uint64 claimOpen = core.getMarket(marketId).settlementTimestamp + core.claimDelaySeconds();
        vm.warp(uint256(claimOpen) + 1);

        uint256 sponsorBefore = payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        core.claimPayout(positionId);

        uint256 sponsorReceived = payment.balanceOf(sponsor) - sponsorBefore;
        uint256 beneficiaryReceived = payment.balanceOf(beneficiary) - beneficiaryBefore;

        assertFalse(position.exists(positionId), "position still exists");
        assertEq(sponsorReceived + beneficiaryReceived, QUANTITY, "total payout mismatch");
        assertEq(sponsorReceived, sponsoredCost, "sponsor principal mismatch");
        assertEq(beneficiaryReceived, QUANTITY - sponsoredCost, "beneficiary profit mismatch");
        assertEq(core.getCurrentBatchId(), batchId, "batch did not process");
    }

    function test_batch_claim_handles_winner_loser_mix_after_batch_processing() public {
        uint64 targetBatch = _targetBatchAfter(uint64(block.timestamp + 120));
        uint256 marketId = _createUniformMarketForBatch(targetBatch);

        address trader = makeAddr("batchTrader");
        _fundAndApprove(trader, 100_000_000);

        uint128 winnerQty = 2_000_000;
        uint128 loserQty = 3_000_000;

        uint256 winnerMaxCost = core.calculateOpenCost(marketId, 0, 2, winnerQty) + 1_000_000;
        uint256 loserMaxCost = core.calculateOpenCost(marketId, 2, 4, loserQty) + 1_000_000;

        uint256 winnerId = position.nextId();
        vm.prank(trader);
        core.openPosition(marketId, 0, 2, winnerQty, winnerMaxCost);

        uint256 loserId = position.nextId();
        vm.prank(trader);
        core.openPosition(marketId, 2, 4, loserQty, loserMaxCost);

        uint64 batchId = _secondarySettleAndSnapshot(marketId, 1_000_000, 8);
        _processBatchesThrough(batchId);

        uint64 claimOpen = core.getMarket(marketId).settlementTimestamp + core.claimDelaySeconds();
        vm.warp(uint256(claimOpen) + 1);

        uint256 balanceBefore = payment.balanceOf(trader);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = winnerId;
        positionIds[1] = loserId;

        vm.prank(trader);
        core.batchClaimPayout(positionIds);

        assertEq(payment.balanceOf(trader) - balanceBefore, winnerQty, "winner payout mismatch");
        assertFalse(position.exists(winnerId), "winner position still exists");
        assertFalse(position.exists(loserId), "loser position still exists");
        assertEq(core.getCurrentBatchId(), batchId, "batch did not process");
    }
}
