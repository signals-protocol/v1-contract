// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Vm.sol";
import "./RedstoneHelper.sol";
import "../../../contracts/testonly/SignalsCoreHarness.sol";

/// @title SettlementHelper
/// @notice Wraps RedstoneHelper + time manipulation into single-call settlement flows.
/// @dev Used by integration/e2e tests that need to settle markets without boilerplate.
library SettlementHelper {
    /// @notice Warp past market end, submit settlement via RedstoneHelper, then finalize.
    /// @dev Full settlement flow: warp → submitSettlementSample → warp past submit window → finalizePrimarySettlement
    /// @param vm_ The Vm cheatcode instance
    /// @param core The SignalsCoreHarness address (must be harness for getSettlementWindows)
    /// @param submitter The address that sends the settlement sample (must be owner/operator)
    /// @param marketId The market ID to settle
    /// @param priceHuman Human-readable price (e.g. 100000 for $100,000 BTC)
    function settleMarket(Vm vm_, address core, address submitter, uint256 marketId, uint256 priceHuman) internal {
        // Get settlement windows (single call)
        (uint64 tSet, uint64 settleEnd,,) = SignalsCoreHarness(core).getSettlementWindows(marketId);

        // Warp to settlement window start (tSet = market.settlementTimestamp)
        vm_.warp(tSet);

        // Submit settlement sample with Redstone payload
        RedstoneHelper.submitWithPayload(vm_, core, submitter, marketId, priceHuman, tSet);

        // Warp past submit window into PendingOps period for finalization
        vm_.warp(settleEnd);

        // Finalize settlement (requires owner/operator)
        vm_.prank(submitter);
        SignalsCoreHarness(core).finalizePrimarySettlement(marketId);
    }

    /// @notice Submit a single settlement sample without finalizing.
    /// @dev Delegates directly to RedstoneHelper.submitWithPayload with matching signature.
    /// @param vm_ The Vm cheatcode instance
    /// @param core The SignalsCore (or harness) address
    /// @param submitter The address that sends the transaction
    /// @param marketId The market ID to settle
    /// @param priceHuman Human-readable price (e.g. 100000 for $100,000 BTC)
    /// @param timestampSec The settlement sample timestamp in seconds
    function submitSample(
        Vm vm_,
        address core,
        address submitter,
        uint256 marketId,
        uint256 priceHuman,
        uint256 timestampSec
    ) internal {
        RedstoneHelper.submitWithPayload(vm_, core, submitter, marketId, priceHuman, timestampSec);
    }
}
