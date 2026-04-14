// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkProtocolTest.sol";

/// @title VaultBatchForkTest
/// @notice Deterministic fork coverage for vault request, cancel, claim, and batch flows.
contract VaultBatchForkTest is ForkProtocolTest {
    function test_deposit_and_withdraw_claim_lifecycle_processes_real_batches() public {
        address lp = makeAddr("lp");
        _fundAndApprove(lp, 1_000_000_000);

        uint256 depositAmount = 300_000_000;
        uint256 balanceBeforeDeposit = payment.balanceOf(lp);

        vm.prank(lp);
        uint64 depositRequestId = core.requestDeposit(depositAmount);

        assertEq(payment.balanceOf(lp), balanceBeforeDeposit - depositAmount, "deposit escrow mismatch");

        uint64 depositBatch = core.getCurrentBatchId() + 1;
        _processBatchesThrough(depositBatch);

        vm.prank(lp);
        uint256 mintedShares = core.claimDeposit(depositRequestId);

        assertGt(mintedShares, 0, "deposit minted no shares");
        assertEq(lpShare.balanceOf(lp), mintedShares, "lp share balance mismatch");

        uint256 withdrawShares = mintedShares / 2;
        uint256 balanceBeforeWithdrawClaim = payment.balanceOf(lp);

        vm.prank(lp);
        uint64 withdrawRequestId = core.requestWithdraw(withdrawShares);

        assertEq(lpShare.balanceOf(lp), mintedShares - withdrawShares, "withdraw burn mismatch");

        uint64 withdrawBatch = core.getCurrentBatchId() + core.getWithdrawalLagBatches() + 1;
        _processBatchesThrough(withdrawBatch);

        vm.prank(lp);
        uint256 withdrawnAssets = core.claimWithdraw(withdrawRequestId);

        assertGt(withdrawnAssets, 0, "withdraw claim returned zero");
        assertGt(payment.balanceOf(lp), balanceBeforeWithdrawClaim, "withdraw claim paid nothing");
        assertEq(lpShare.balanceOf(lp), mintedShares - withdrawShares, "lp shares changed after claim");
    }

    function test_deposit_and_withdraw_requests_can_be_cancelled_before_processing() public {
        address lp = makeAddr("cancelLp");
        _fundAndApprove(lp, 1_000_000_000);

        uint256 cancelDepositAmount = 250_000_000;
        uint256 balanceBeforeDeposit = payment.balanceOf(lp);

        vm.startPrank(lp);
        uint64 depositRequestId = core.requestDeposit(cancelDepositAmount);
        core.cancelDeposit(depositRequestId);
        vm.stopPrank();

        assertEq(payment.balanceOf(lp), balanceBeforeDeposit, "deposit cancel did not refund");

        vm.prank(lp);
        uint64 claimableDepositId = core.requestDeposit(300_000_000);

        uint64 depositBatch = core.getCurrentBatchId() + 1;
        _processBatchesThrough(depositBatch);

        vm.prank(lp);
        uint256 mintedShares = core.claimDeposit(claimableDepositId);

        vm.prank(lp);
        uint64 withdrawRequestId = core.requestWithdraw(mintedShares / 2);

        uint256 lpSharesAfterBurn = lpShare.balanceOf(lp);
        vm.prank(lp);
        core.cancelWithdraw(withdrawRequestId);

        assertEq(
            lpShare.balanceOf(lp),
            lpSharesAfterBurn + (mintedShares / 2),
            "withdraw cancel did not restore shares"
        );
    }
}
