// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../vault/lib/VaultAccountingLib.sol";
import "../lib/FeeWaterfallLib.sol";
import "../lib/FixedPointMathU.sol";
import "../errors/ModuleErrors.sol";
import "../errors/CLMSRErrors.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LPVaultModule
 * @notice Delegate-only module for LP Vault operations
 * @dev Implements Request ID-based queue with O(1) batch processing
 *
 * Architecture:
 * - Request ID model: Each deposit/withdraw gets unique ID
 * - Pre-aggregation: Totals computed at request time, not batch time
 * - O(1) batch processing: No for-loop over users
 * - Claim-based: Users claim shares/assets after batch processes
 *
 * Flow:
 * 1. User calls requestDeposit/requestWithdraw → gets requestId
 * 2. Request recorded with eligibleBatchId (D_lag applied for withdrawals)
 * 3. processDailyBatch(batchId) processes pre-aggregated totals
 * 4. User calls claimDeposit/claimWithdraw to receive shares/assets
 *
 * References: whitepaper Section 3, 4.3-4.6
 */
contract LPVaultModule is SignalsCoreStorage {
    using SafeERC20 for IERC20;
    using VaultAccountingLib for *;
    using FixedPointMathU for uint256;

    address private immutable self;

    // ============================================================
    // Events
    // ============================================================
    event VaultSeeded(address indexed seeder, uint256 amount, uint256 shares);

    event DailyBatchProcessed(
        uint64 indexed batchId,
        int256 lt,           // CLMSR P&L
        uint256 ftot,        // Gross fees
        uint256 ft,          // LP-attributed fees
        uint256 gt,          // Backstop grant
        uint256 navPre,      // Pre-batch NAV
        uint256 batchPrice,  // Batch equity price
        uint256 navPost,     // Post-batch NAV
        uint256 pricePost,   // Post-batch price
        uint256 drawdown     // Drawdown from peak
    );

    event DepositRequestCreated(
        uint64 indexed requestId,
        address indexed owner,
        uint256 amount,
        uint64 eligibleBatchId
    );

    event WithdrawRequestCreated(
        uint64 indexed requestId,
        address indexed owner,
        uint256 shares,
        uint64 eligibleBatchId
    );

    event DepositRequestCancelled(uint64 indexed requestId, address indexed owner, uint256 amount);
    event WithdrawRequestCancelled(uint64 indexed requestId, address indexed owner, uint256 shares);
    event DepositClaimed(uint64 indexed requestId, address indexed owner, uint256 amount, uint256 shares);
    event WithdrawClaimed(uint64 indexed requestId, address indexed owner, uint256 shares, uint256 assets);

    // ============================================================
    // Errors
    // ============================================================
    error NotDelegated();
    error VaultNotSeeded();
    error VaultAlreadySeeded();
    error InsufficientSeedAmount(uint256 provided, uint256 required);
    error ZeroAmount();
    error BatchNotReady(uint64 batchId);
    error DailyBatchAlreadyProcessed(uint64 batchId);
    error RequestNotFound(uint64 requestId);
    error RequestNotOwned(uint64 requestId, address owner, address caller);
    error RequestNotPending(uint64 requestId);
    error BatchNotProcessed(uint64 batchId);

    // ============================================================
    // Modifiers
    // ============================================================
    modifier onlyDelegated() {
        if (address(this) == self) revert NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // ============================================================
    // Seeding
    // ============================================================

    /**
     * @notice Seed the vault with initial capital
     * @dev Must be called before any batch processing
     *      seedAmount is in payment token decimals (6), converted to WAD (18) for internal accounting
     * @param seedAmount Initial deposit amount (6 decimals)
     */
    function seedVault(uint256 seedAmount) external onlyDelegated {
        if (lpVault.isSeeded) revert VaultAlreadySeeded();
        if (seedAmount < minSeedAmount) {
            revert InsufficientSeedAmount(seedAmount, minSeedAmount);
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), seedAmount);

        // Phase 6: Convert 6-decimal token amount to WAD (18) for internal accounting
        // WP v2 Sec 6.2: "Internal state uses WAD; conversion at entry/exit"
        uint256 seedAmountWad = seedAmount.toWad();
        
        lpVault.nav = seedAmountWad;
        lpVault.shares = seedAmountWad;
        lpVault.price = VaultAccountingLib.WAD;
        lpVault.pricePeak = VaultAccountingLib.WAD;
        lpVault.lastBatchTimestamp = uint64(block.timestamp);
        lpVault.isSeeded = true;

        // Initialize currentBatchId as a day-key so that:
        // - MarketLifecycleModule records P&L into batchId = settlementTimestamp / BATCH_SECONDS
        // - LPVaultModule processes batches strictly sequentially (currentBatchId + 1)
        //
        // We set currentBatchId to "yesterday" so the first processDailyBatch targets "today".
        uint64 todayBatchId = uint64(block.timestamp / uint256(BATCH_SECONDS));
        currentBatchId = todayBatchId == 0 ? 0 : todayBatchId - 1;

        // Event emits WAD amounts for consistency with internal accounting
        emit VaultSeeded(msg.sender, seedAmountWad, seedAmountWad);
    }

    // ============================================================
    // Request Queue (Request ID Model)
    // ============================================================

    /**
     * @notice Request a deposit into the vault
     * @dev Tokens transferred immediately (6 decimals), internally stored as WAD
     *      WP v2 Sec 6.2: "Convert at entry, internal ops in WAD"
     * @param amount Amount to deposit (in payment token decimals, 6)
     * @return requestId Unique request identifier
     */
    function requestDeposit(uint256 amount) external onlyDelegated returns (uint64 requestId) {
        if (amount == 0) revert ZeroAmount();
        if (!lpVault.isSeeded) revert VaultNotSeeded();

        // Transfer 6-decimal tokens
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        // Phase 6: Track pending deposits for free balance calculation
        _totalPendingDeposits6 += amount;

        // Phase 6: Convert to WAD for internal accounting
        uint256 amountWad = amount.toWad();

        requestId = nextDepositRequestId++;
        uint64 eligibleBatchId = currentBatchId + 1;

        _depositRequests[requestId] = DepositRequest({
            id: requestId,
            owner: msg.sender,
            amount: amountWad,  // Stored as WAD
            eligibleBatchId: eligibleBatchId,
            status: RequestStatus.Pending
        });

        _pendingBatchTotals[eligibleBatchId].deposits += amountWad;

        emit DepositRequestCreated(requestId, msg.sender, amountWad, eligibleBatchId);
    }

    /**
     * @notice Request a withdrawal from the vault
     * @dev D_lag determines when withdrawal becomes eligible
     * @param shares Number of shares to withdraw
     * @return requestId Unique request identifier
     */
    function requestWithdraw(uint256 shares) external onlyDelegated returns (uint64 requestId) {
        if (shares == 0) revert ZeroAmount();
        if (!lpVault.isSeeded) revert VaultNotSeeded();

        requestId = nextWithdrawRequestId++;
        uint64 eligibleBatchId = currentBatchId + withdrawalLagBatches + 1;

        _withdrawRequests[requestId] = WithdrawRequest({
            id: requestId,
            owner: msg.sender,
            shares: shares,
            eligibleBatchId: eligibleBatchId,
            status: RequestStatus.Pending
        });

        _pendingBatchTotals[eligibleBatchId].withdraws += shares;

        emit WithdrawRequestCreated(requestId, msg.sender, shares, eligibleBatchId);
    }

    /**
     * @notice Cancel a pending deposit request
     * @dev Converts WAD amount back to 6 decimals for refund
     * @param requestId Request identifier to cancel
     */
    function cancelDeposit(uint64 requestId) external onlyDelegated {
        DepositRequest storage req = _depositRequests[requestId];

        if (req.owner == address(0)) revert RequestNotFound(requestId);
        if (req.owner != msg.sender) revert RequestNotOwned(requestId, req.owner, msg.sender);
        if (req.status != RequestStatus.Pending) revert RequestNotPending(requestId);

        uint256 amountWad = req.amount;  // Stored as WAD
        uint64 eligibleBatchId = req.eligibleBatchId;

        req.status = RequestStatus.Cancelled;
        _pendingBatchTotals[eligibleBatchId].deposits -= amountWad;

        // Phase 6: Convert WAD to 6 decimals for token transfer
        // WP v2 Appendix C: deposit residual refunded to depositor (no dust retained)
        uint256 amount6 = amountWad.fromWad();
        
        // Phase 6: Decrease pending deposits (funds are reserved, no free balance check needed)
        _totalPendingDeposits6 -= amount6;
        paymentToken.safeTransfer(msg.sender, amount6);

        emit DepositRequestCancelled(requestId, msg.sender, amountWad);
    }

    /**
     * @notice Cancel a pending withdrawal request
     * @param requestId Request identifier to cancel
     */
    function cancelWithdraw(uint64 requestId) external onlyDelegated {
        WithdrawRequest storage req = _withdrawRequests[requestId];

        if (req.owner == address(0)) revert RequestNotFound(requestId);
        if (req.owner != msg.sender) revert RequestNotOwned(requestId, req.owner, msg.sender);
        if (req.status != RequestStatus.Pending) revert RequestNotPending(requestId);

        uint256 shares = req.shares;
        uint64 eligibleBatchId = req.eligibleBatchId;

        req.status = RequestStatus.Cancelled;
        _pendingBatchTotals[eligibleBatchId].withdraws -= shares;

        emit WithdrawRequestCancelled(requestId, msg.sender, shares);
    }

    // ============================================================
    // Batch Processing (O(1) Complexity)
    // ============================================================

    /**
     * @notice Record daily P&L from market settlement
     * @dev Called by MarketLifecycleModule after settleMarket
     * @param batchId Batch identifier
     * @param lt CLMSR P&L (signed)
     * @param ftot Gross fees
     */
    function recordDailyPnl(uint64 batchId, int256 lt, uint256 ftot) external onlyDelegated {
        DailyPnlSnapshot storage snap = _dailyPnl[batchId];
        if (snap.processed) revert DailyBatchAlreadyProcessed(batchId);
        snap.Lt += lt;
        snap.Ftot += ftot;
    }

    /**
     * @notice Process daily batch using pre-aggregated totals
     * @dev O(1) complexity - no iteration over users
     *
     *      Flow:
     *      1. Validate batch ID sequence
     *      2. Read pre-aggregated totals from _pendingBatchTotals
     *      3. Apply Fee Waterfall (whitepaper Sec 4.3-4.6)
     *      4. Process withdrawals then deposits
     *      5. Store batch result for claims
     *
     * @param batchId Batch identifier (must be currentBatchId + 1)
     */
    function processDailyBatch(uint64 batchId) external onlyDelegated {
        if (!lpVault.isSeeded) revert VaultNotSeeded();
        if (batchId != currentBatchId + 1) revert BatchNotReady(batchId);

        DailyPnlSnapshot storage snap = _dailyPnl[batchId];
        if (snap.processed) revert DailyBatchAlreadyProcessed(batchId);

        // Step 1: Get pre-aggregated totals (O(1))
        PendingBatchTotal storage pending = _pendingBatchTotals[batchId];
        uint256 totalWithdraws = pending.withdraws;
        uint256 totalDeposits = pending.deposits;

        // Step 2: Run Fee Waterfall
        FeeWaterfallLib.Params memory params = FeeWaterfallLib.Params({
            Lt: snap.Lt,
            Ftot: snap.Ftot,
            Nprev: lpVault.nav,
            Bprev: capitalStack.backstopNav,
            Tprev: capitalStack.treasuryNav,
            deltaEt: _getDeltaEt(),
            pdd: feeWaterfallConfig.pdd,
            rhoBS: feeWaterfallConfig.rhoBS,
            phiLP: feeWaterfallConfig.phiLP,
            phiBS: feeWaterfallConfig.phiBS,
            phiTR: feeWaterfallConfig.phiTR
        });

        FeeWaterfallLib.Result memory wf = FeeWaterfallLib.calculate(params);

        // Step 3: Apply pre-batch with waterfall result
        (uint256 navPre, uint256 batchPrice) = VaultAccountingLib.applyPreBatchFromWaterfall(
            lpVault.nav,
            lpVault.shares,
            snap.Lt,
            wf
        );

        // Step 4: Process withdrawals first (at batch price)
        uint256 currentNav = navPre;
        uint256 currentShares = lpVault.shares;

        if (totalWithdraws > 0) {
            (currentNav, currentShares, ) = VaultAccountingLib.applyWithdraw(
                currentNav,
                currentShares,
                batchPrice,
                totalWithdraws
            );
        }

        // Step 5: Process deposits (at batch price)
        if (totalDeposits > 0) {
            (currentNav, currentShares, , ) = VaultAccountingLib.applyDeposit(
                currentNav,
                currentShares,
                batchPrice,
                totalDeposits
            );
            // Phase 6: Release pending deposits (now converted to shares)
            _totalPendingDeposits6 -= totalDeposits.fromWad();
        }

        // Step 6: Compute final state
        VaultAccountingLib.PostBatchState memory postBatch = VaultAccountingLib.computePostBatchState(
            currentNav,
            currentShares,
            lpVault.pricePeak
        );

        // Step 7: Update LP Vault storage
        lpVault.nav = postBatch.nav;
        lpVault.shares = postBatch.shares;
        lpVault.price = postBatch.price;
        lpVault.pricePeak = postBatch.pricePeak;
        lpVault.lastBatchTimestamp = uint64(block.timestamp);

        // Step 8: Update Capital Stack
        capitalStack.backstopNav = wf.Bnext;
        capitalStack.treasuryNav = wf.Tnext;

        // Step 9: Store batch aggregation for claims
        _batchAggregations[batchId] = BatchAggregation({
            totalDepositAssets: totalDeposits,
            totalWithdrawShares: totalWithdraws,
            batchPrice: batchPrice,
            processed: true
        });

        // Step 10: Record snapshot for audit trail
        snap.Floss = wf.Floss;
        snap.Fpool = wf.Fpool;
        snap.Nraw = wf.Nraw;
        snap.Gt = wf.Gt;
        snap.Ffill = wf.Ffill;
        snap.Fdust = wf.Fdust;
        snap.Ft = wf.Ft;
        snap.Npre = navPre;
        snap.Pe = batchPrice;
        snap.processed = true;

        // Step 11: Advance batch ID
        currentBatchId = batchId;

        emit DailyBatchProcessed(
            batchId,
            snap.Lt,
            snap.Ftot,
            wf.Ft,
            wf.Gt,
            navPre,
            batchPrice,
            postBatch.nav,
            postBatch.price,
            postBatch.drawdown
        );
    }

    /**
     * @notice Get available backstop support limit (ΔE_t)
     * @return deltaEt Available backstop support limit
     */
    function _getDeltaEt() internal view returns (uint256) {
        return capitalStack.backstopNav;
    }

    /**
     * @notice Calculate free balance available for withdrawals and payouts
     * @dev Free balance = token balance - pending deposits - payout reserves
     *      Ensures pending deposits are isolated and cannot be used for other payments
     * @return Free balance in 6-decimal token units
     */
    function _getFreeBalance() internal view returns (uint256) {
        uint256 balance = paymentToken.balanceOf(address(this));
        uint256 reserved = _totalPendingDeposits6 + _totalPayoutReserve6;
        return balance > reserved ? balance - reserved : 0;
    }

    /**
     * @notice Revert if requested amount exceeds free balance
     * @dev Phase 6 escrow safety: prevents use of pending deposits for payouts
     * @param amount6 Amount requested in 6-decimal token units
     */
    function _requireFreeBalance(uint256 amount6) internal view {
        uint256 free = _getFreeBalance();
        if (amount6 > free) revert CE.InsufficientFreeBalance(amount6, free);
    }

    // ============================================================
    // Claims
    // ============================================================

    /**
     * @notice Claim shares from a processed deposit request
     * @dev Calculates shares = amount / batchPrice
     * @param requestId Deposit request identifier
     * @return shares Number of shares claimable
     */
    function claimDeposit(uint64 requestId) external onlyDelegated returns (uint256 shares) {
        DepositRequest storage req = _depositRequests[requestId];

        if (req.owner == address(0)) revert RequestNotFound(requestId);
        if (req.owner != msg.sender) revert RequestNotOwned(requestId, req.owner, msg.sender);
        if (req.status != RequestStatus.Pending) revert RequestNotPending(requestId);

        BatchAggregation storage agg = _batchAggregations[req.eligibleBatchId];
        if (!agg.processed) revert BatchNotProcessed(req.eligibleBatchId);

        shares = req.amount.wDiv(agg.batchPrice);
        req.status = RequestStatus.Claimed;

        // Note: Phase 7 will mint ERC-4626 LP tokens here

        emit DepositClaimed(requestId, msg.sender, req.amount, shares);
    }

    /**
     * @notice Claim assets from a processed withdrawal request
     * @dev Calculates assets = shares * batchPrice (WAD), converts to 6 decimals for transfer
     *      WP v2 Appendix C: withdrawal dust stays in vault (LP benefit) - truncate
     * @param requestId Withdraw request identifier
     * @return assets Amount of assets claimable (in WAD for return value)
     */
    function claimWithdraw(uint64 requestId) external onlyDelegated returns (uint256 assets) {
        WithdrawRequest storage req = _withdrawRequests[requestId];

        if (req.owner == address(0)) revert RequestNotFound(requestId);
        if (req.owner != msg.sender) revert RequestNotOwned(requestId, req.owner, msg.sender);
        if (req.status != RequestStatus.Pending) revert RequestNotPending(requestId);

        BatchAggregation storage agg = _batchAggregations[req.eligibleBatchId];
        if (!agg.processed) revert BatchNotProcessed(req.eligibleBatchId);

        assets = req.shares.wMul(agg.batchPrice);  // WAD result
        req.status = RequestStatus.Claimed;

        // Phase 6: Convert WAD to 6 decimals for token transfer
        // WP v2 Appendix C: "Withdrawal dust stays in vault (LP benefit)" - truncate (round down)
        uint256 assets6 = assets.fromWad();
        
        // Phase 6: Verify free balance (escrow safety)
        // Withdrawals must not use pending deposits or payout reserves
        _requireFreeBalance(assets6);
        paymentToken.safeTransfer(msg.sender, assets6);

        emit WithdrawClaimed(requestId, msg.sender, req.shares, assets);
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

    function isVaultSeeded() external view returns (bool) {
        return lpVault.isSeeded;
    }

    function getVaultPricePeak() external view returns (uint256) {
        return lpVault.pricePeak;
    }

    function getVaultDrawdown() external view returns (uint256) {
        return VaultAccountingLib.computeDrawdown(lpVault.price, lpVault.pricePeak);
    }

    function getCapitalStack() external view returns (uint256 backstopNav, uint256 treasuryNav) {
        return (capitalStack.backstopNav, capitalStack.treasuryNav);
    }

    function getFeeWaterfallConfig() external view returns (
        int256 pdd,
        uint256 rhoBS,
        uint256 phiLP,
        uint256 phiBS,
        uint256 phiTR
    ) {
        return (
            feeWaterfallConfig.pdd,
            feeWaterfallConfig.rhoBS,
            feeWaterfallConfig.phiLP,
            feeWaterfallConfig.phiBS,
            feeWaterfallConfig.phiTR
        );
    }

    function getDailyPnl(uint64 batchId) external view returns (
        int256 lt,
        uint256 ftot,
        uint256 ft,
        uint256 gt,
        uint256 npre,
        uint256 pe,
        bool processed
    ) {
        DailyPnlSnapshot storage snap = _dailyPnl[batchId];
        return (snap.Lt, snap.Ftot, snap.Ft, snap.Gt, snap.Npre, snap.Pe, snap.processed);
    }

    function getDepositRequest(uint64 requestId) external view returns (
        uint64 id,
        address owner,
        uint256 amount,
        uint64 eligibleBatchId,
        RequestStatus status
    ) {
        DepositRequest storage req = _depositRequests[requestId];
        return (req.id, req.owner, req.amount, req.eligibleBatchId, req.status);
    }

    function getWithdrawRequest(uint64 requestId) external view returns (
        uint64 id,
        address owner,
        uint256 shares,
        uint64 eligibleBatchId,
        RequestStatus status
    ) {
        WithdrawRequest storage req = _withdrawRequests[requestId];
        return (req.id, req.owner, req.shares, req.eligibleBatchId, req.status);
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

    function getCurrentBatchId() external view returns (uint64) {
        return currentBatchId;
    }

    function getWithdrawalLagBatches() external view returns (uint64) {
        return withdrawalLagBatches;
    }
}
