// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Vm.sol";
import "./SignalsBaseTest.sol";
import "../../../contracts/testonly/SignalsCoreHarness.sol";
import "../../../contracts/testonly/SignalsUSDToken.sol";

/// @title VaultHelper
/// @notice Vault seeding + batch processing convenience functions for tests.
/// @dev Wraps multi-step vault deposit/process/claim flows into single calls.
///      Uses SignalsCoreHarness to bypass lifecycle requirements where needed.
library VaultHelper {
    uint64 internal constant BATCH_SECONDS = 86_400;
    uint64 internal constant PST_OFFSET_SECONDS = 28_800;

    // ============================================================
    // Batch time helpers (mirrors SignalsBaseTest)
    // ============================================================

    function _batchStartTimestamp(uint64 id) private pure returns (uint64) {
        return id * BATCH_SECONDS + PST_OFFSET_SECONDS;
    }

    function _batchEndTimestamp(uint64 id) private pure returns (uint64) {
        return _batchStartTimestamp(id + 1);
    }

    // ============================================================
    // Core helpers
    // ============================================================

    /// @notice Seed vault with initial liquidity: approve → seedVault
    /// @param vm_ The Vm cheatcode instance
    /// @param core The SignalsCoreHarness address
    /// @param depositor The address providing seed funds
    /// @param amount Seed amount in 6-decimal token units
    function seedVault(Vm vm_, address core, address depositor, uint256 amount) internal {
        SignalsCoreHarness coreContract = SignalsCoreHarness(core);
        address paymentToken = address(coreContract.paymentToken());

        vm_.startPrank(depositor);
        SignalsUSDToken(paymentToken).approve(core, amount);
        coreContract.seedVault(amount);
        vm_.stopPrank();
    }

    /// @notice Warp past batch end and call processDailyBatch(batchId)
    /// @dev Ensures batch market state is set (1 resolved market) before processing
    /// @param vm_ The Vm cheatcode instance
    /// @param core The SignalsCoreHarness address
    /// @param batchId The batch ID to process
    function processBatch(Vm vm_, address core, uint64 batchId) internal {
        SignalsCoreHarness coreContract = SignalsCoreHarness(core);
        address owner = coreContract.owner();

        // Ensure batch market state is set so processDailyBatch doesn't revert
        // Default: 1 market total, 1 resolved (matching LPVaultModuleProxy harness behavior)
        vm_.prank(owner);
        coreContract.harnessSetBatchMarketState(batchId, 1, 1);

        // Warp past batch end
        vm_.warp(_batchEndTimestamp(batchId) + 1);

        // Process the batch (onlyOwnerOrOperator)
        vm_.prank(owner);
        coreContract.processDailyBatch(batchId);
    }

    /// @notice Full deposit flow: approve → requestDeposit → warp → processBatch → claimDeposit → return shares
    /// @param vm_ The Vm cheatcode instance
    /// @param core The SignalsCoreHarness address
    /// @param user The address depositing
    /// @param amount Deposit amount in 6-decimal token units
    /// @return shares The LP shares received
    function depositAndClaim(Vm vm_, address core, address user, uint256 amount) internal returns (uint256 shares) {
        SignalsCoreHarness coreContract = SignalsCoreHarness(core);
        address paymentToken = address(coreContract.paymentToken());

        // Approve and request deposit
        vm_.startPrank(user);
        SignalsUSDToken(paymentToken).approve(core, amount);
        uint64 requestId = coreContract.requestDeposit(amount);
        vm_.stopPrank();

        // Get the eligible batch ID (current + 1)
        uint64 currentBatch = coreContract.getCurrentBatchId();
        uint64 eligibleBatch = currentBatch + 1;

        // Process the eligible batch
        processBatch(vm_, core, eligibleBatch);

        // Claim deposit
        vm_.prank(user);
        shares = coreContract.claimDeposit(requestId);
    }
}
