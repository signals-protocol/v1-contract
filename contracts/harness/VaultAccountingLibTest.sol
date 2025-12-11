// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../vault/lib/VaultAccountingLib.sol";

/**
 * @title VaultAccountingLibTest
 * @notice Test harness to expose VaultAccountingLib functions
 */
contract VaultAccountingLibTest {
    using VaultAccountingLib for *;

    function computePreBatch(
        uint256 navPrev,
        uint256 sharesPrev,
        int256 pnl,
        uint256 fees,
        uint256 grant
    ) external pure returns (uint256 navPre, uint256 batchPrice) {
        VaultAccountingLib.PreBatchInputs memory inputs = VaultAccountingLib.PreBatchInputs({
            navPrev: navPrev,
            sharesPrev: sharesPrev,
            pnl: pnl,
            fees: fees,
            grant: grant
        });
        VaultAccountingLib.PreBatchResult memory result = VaultAccountingLib.computePreBatch(inputs);
        return (result.navPre, result.batchPrice);
    }

    function computePreBatchForSeed(
        uint256 navPrev,
        int256 pnl,
        uint256 fees,
        uint256 grant
    ) external pure returns (uint256 navPre, uint256 batchPrice) {
        return VaultAccountingLib.computePreBatchForSeed(navPrev, pnl, fees, grant);
    }

    function applyDeposit(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 depositAmount
    ) external pure returns (uint256 newNav, uint256 newShares, uint256 mintedShares) {
        return VaultAccountingLib.applyDeposit(nav, shares, price, depositAmount);
    }

    function applyWithdraw(
        uint256 nav,
        uint256 shares,
        uint256 price,
        uint256 withdrawShares
    ) external pure returns (uint256 newNav, uint256 newShares, uint256 withdrawAmount) {
        return VaultAccountingLib.applyWithdraw(nav, shares, price, withdrawShares);
    }

    function updatePeak(uint256 currentPeak, uint256 newPrice) external pure returns (uint256) {
        return VaultAccountingLib.updatePeak(currentPeak, newPrice);
    }

    function computeDrawdown(uint256 price, uint256 peak) external pure returns (uint256) {
        return VaultAccountingLib.computeDrawdown(price, peak);
    }

    function computePrice(uint256 nav, uint256 shares) external pure returns (uint256) {
        return VaultAccountingLib.computePrice(nav, shares);
    }

    function computePostBatchState(
        uint256 nav,
        uint256 shares,
        uint256 previousPeak
    ) external pure returns (
        uint256 navOut,
        uint256 sharesOut,
        uint256 price,
        uint256 pricePeak,
        uint256 drawdown
    ) {
        VaultAccountingLib.PostBatchState memory state = VaultAccountingLib.computePostBatchState(
            nav, shares, previousPeak
        );
        return (state.nav, state.shares, state.price, state.pricePeak, state.drawdown);
    }
}

