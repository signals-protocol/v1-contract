// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../modules/LPVaultModule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LPVaultModuleProxy
 * @notice Test harness to delegate calls to LPVaultModule
 * @dev Provides storage context for delegate calls
 */
contract LPVaultModuleProxy is SignalsCoreStorage {
    address public module;

    constructor(address _module) {
        module = _module;
    }

    // ============================================================
    // Setup
    // ============================================================

    function setPaymentToken(address token) external {
        paymentToken = IERC20(token);
    }

    function setMinSeedAmount(uint256 amount) external {
        minSeedAmount = amount;
    }

    function setWithdrawLag(uint64 lag) external {
        withdrawLag = lag;
    }

    function setWithdrawalLagBatches(uint64 lag) external {
        withdrawalLagBatches = lag;
    }

    function setFeeWaterfallConfig(
        int256 pdd,
        uint256 rhoBS,
        uint256 phiLP,
        uint256 phiBS,
        uint256 phiTR
    ) external {
        feeWaterfallConfig.pdd = pdd;
        feeWaterfallConfig.rhoBS = rhoBS;
        feeWaterfallConfig.phiLP = phiLP;
        feeWaterfallConfig.phiBS = phiBS;
        feeWaterfallConfig.phiTR = phiTR;
    }

    function setCapitalStack(uint256 backstopNav, uint256 treasuryNav) external {
        capitalStack.backstopNav = backstopNav;
        capitalStack.treasuryNav = treasuryNav;
    }

    // ============================================================
    // Seeding
    // ============================================================

    function seedVault(uint256 seedAmount) external {
        _delegate(abi.encodeWithSelector(LPVaultModule.seedVault.selector, seedAmount));
    }

    // ============================================================
    // Request Queue (Request ID Model)
    // ============================================================

    function requestDeposit(uint256 amount) external returns (uint64) {
        bytes memory ret = _delegate(abi.encodeWithSelector(
            LPVaultModule.requestDeposit.selector,
            amount
        ));
        return abi.decode(ret, (uint64));
    }

    function requestWithdraw(uint256 shares) external returns (uint64) {
        bytes memory ret = _delegate(abi.encodeWithSelector(
            LPVaultModule.requestWithdraw.selector,
            shares
        ));
        return abi.decode(ret, (uint64));
    }

    function cancelDeposit(uint64 requestId) external {
        _delegate(abi.encodeWithSelector(
            LPVaultModule.cancelDeposit.selector,
            requestId
        ));
    }

    function cancelWithdraw(uint64 requestId) external {
        _delegate(abi.encodeWithSelector(
            LPVaultModule.cancelWithdraw.selector,
            requestId
        ));
    }

    // ============================================================
    // Batch Processing
    // ============================================================

    function recordDailyPnl(uint64 batchId, int256 lt, uint256 ftot) external {
        _delegate(abi.encodeWithSelector(
            LPVaultModule.recordDailyPnl.selector,
            batchId,
            lt,
            ftot
        ));
    }

    function processDailyBatch(uint64 batchId) external {
        _delegate(abi.encodeWithSelector(
            LPVaultModule.processDailyBatch.selector,
            batchId
        ));
    }

    // ============================================================
    // Claims
    // ============================================================

    function claimDeposit(uint64 requestId) external returns (uint256) {
        bytes memory ret = _delegate(abi.encodeWithSelector(
            LPVaultModule.claimDeposit.selector,
            requestId
        ));
        return abi.decode(ret, (uint256));
    }

    function claimWithdraw(uint64 requestId) external returns (uint256) {
        bytes memory ret = _delegate(abi.encodeWithSelector(
            LPVaultModule.claimWithdraw.selector,
            requestId
        ));
        return abi.decode(ret, (uint256));
    }

    // ============================================================
    // View Functions
    // ============================================================

    function getVaultNav() external view returns (uint256) {
        return lpVault.nav;
    }

    function getVaultShares() external view returns (uint256) {
        return lpVault.shares;
    }

    function getVaultPrice() external view returns (uint256) {
        return lpVault.price;
    }

    function getVaultPricePeak() external view returns (uint256) {
        return lpVault.pricePeak;
    }

    function isVaultSeeded() external view returns (bool) {
        return lpVault.isSeeded;
    }

    function getCapitalStack() external view returns (uint256 backstopNav, uint256 treasuryNav) {
        return (capitalStack.backstopNav, capitalStack.treasuryNav);
    }

    function getPendingBatchTotals(uint64 batchId) external view returns (
        uint256 deposits,
        uint256 withdraws
    ) {
        PendingBatchTotal storage totals = _pendingBatchTotals[batchId];
        return (totals.deposits, totals.withdraws);
    }

    function getBatchAggregation(uint64 batchId) external view returns (
        uint256 totalDepositAssets,
        uint256 totalWithdrawShares,
        uint256 batchPrice,
        bool processed
    ) {
        BatchAggregation storage agg = _batchAggregations[batchId];
        return (agg.totalDepositAssets, agg.totalWithdrawShares, agg.batchPrice, agg.processed);
    }

    function getDailyPnl(uint64 batchId) external view returns (
        int256 Lt,
        uint256 Ftot,
        uint256 Ft,
        uint256 Gt,
        uint256 Npre,
        uint256 Pe,
        bool processed
    ) {
        DailyPnlSnapshot storage snap = _dailyPnl[batchId];
        return (
            snap.Lt,
            snap.Ftot,
            snap.Ft,
            snap.Gt,
            snap.Npre,
            snap.Pe,
            snap.processed
        );
    }

    function getCurrentBatchId() external view returns (uint64) {
        return currentBatchId;
    }

    // ============================================================
    // Internal
    // ============================================================

    function _delegate(bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
