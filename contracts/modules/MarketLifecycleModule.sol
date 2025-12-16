// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../errors/ModuleErrors.sol";
import "../errors/CLMSRErrors.sol";
import "../lib/LazyMulSegmentTree.sol";
import "../lib/FixedPointMathU.sol";

/// @notice Delegate-only lifecycle module (skeleton)
contract MarketLifecycleModule is SignalsCoreStorage {
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;
    using FixedPointMathU for uint256;

    address private immutable self;

    uint256 internal constant WAD = 1e18;

    event SettlementChunkRequested(uint256 indexed marketId, uint32 indexed chunkIndex);
    event MarketCreated(uint256 indexed marketId);
    event MarketSettled(
        uint256 indexed marketId,
        int256 settlementValue,
        int256 settlementTick,
        uint64 settlementTimestamp
    );
    /// @dev Phase 6: P&L recorded to daily batch
    event MarketPnlRecorded(
        uint256 indexed marketId,
        uint64 indexed batchId,
        int256 lt,
        uint256 ftot
    );
    event MarketReopened(uint256 indexed marketId);
    event MarketFailed(uint256 indexed marketId, uint64 timestamp);
    event MarketSettledSecondary(
        uint256 indexed marketId,
        int256 settlementValue,
        int256 settlementTick,
        uint64 settlementFinalizedAt
    );
    event MarketActivationUpdated(uint256 indexed marketId, bool isActive);
    event MarketTimingUpdated(
        uint256 indexed marketId,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp
    );

    uint32 private constant MAX_BIN_COUNT = 1_000_000;
    uint32 public constant CHUNK_SIZE = 512;

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // --- External ---

    /// @notice Create a new market with prior-based factors (Phase 7)
    /// @dev Per WP v2: Factors define the opening prior q₀,t
    ///      - Uniform prior: all factors = 1 WAD → ΔEₜ = 0
    ///      - Concentrated prior: factors vary → ΔEₜ > 0
    ///      Prior admissibility is checked: ΔEₜ ≤ B_eff
    function createMarket(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp,
        uint32 numBins,
        uint256 liquidityParameter,
        address feePolicy,
        uint256[] calldata baseFactors
    ) external onlyDelegated returns (uint256 marketId) {
        _validateMarketParams(minTick, maxTick, tickSpacing, startTimestamp, endTimestamp, settlementTimestamp);
        if (numBins == 0) revert CE.BinCountExceedsLimit(0, MAX_BIN_COUNT);
        if (numBins > MAX_BIN_COUNT) revert CE.BinCountExceedsLimit(numBins, MAX_BIN_COUNT);
        uint32 expectedBins = uint32(uint256((maxTick - minTick) / tickSpacing));
        if (expectedBins != numBins) revert CE.InvalidMarketParameters(minTick, maxTick, tickSpacing);
        if (liquidityParameter == 0) revert CE.InvalidLiquidityParameter();
        if (baseFactors.length != numBins) revert CE.InvalidMarketParameters(minTick, maxTick, tickSpacing);
        
        // Phase 7: α Safety enforcement (WP v2 Sec 4.5)
        _validateAlphaForMarket(liquidityParameter, numBins);

        // Calculate minFactor and rootSum from baseFactors for ΔEₜ calculation
        uint256 minFactor = type(uint256).max;
        uint256 rootSum = 0;
        for (uint256 i = 0; i < numBins; i++) {
            if (baseFactors[i] == 0) revert CE.InvalidFactor(baseFactors[i]);
            if (baseFactors[i] < minFactor) minFactor = baseFactors[i];
            rootSum += baseFactors[i];
        }

        // Phase 7: Prior admissibility check (WP v2 Sec 4.1)
        // ΔEₜ := α * ln(rootSum / (n * minFactor))
        // Admissibility: ΔEₜ ≤ B_eff_{t-1} ≤ backstopNav
        uint256 deltaEt = _calculateDeltaEt(liquidityParameter, numBins, rootSum, minFactor);
        _validatePriorAdmissibility(deltaEt);

        marketId = ++nextMarketId;
        ISignalsCore.Market storage market = markets[marketId];
        market.isActive = true;
        market.settled = false;
        market.snapshotChunksDone = false;
        market.numBins = numBins;
        market.openPositionCount = 0;
        market.snapshotChunkCursor = 0;
        market.startTimestamp = startTimestamp;
        market.endTimestamp = endTimestamp;
        market.settlementTimestamp = settlementTimestamp;
        market.minTick = minTick;
        market.maxTick = maxTick;
        market.tickSpacing = tickSpacing;
        market.settlementTick = 0;
        market.settlementValue = 0;
        market.liquidityParameter = liquidityParameter;
        market.feePolicy = feePolicy;
        market.minFactor = minFactor; // Phase 7: Store for ΔEₜ calculation

        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        tree.init(numBins);
        tree.seedWithFactors(baseFactors);

        // Phase 6: Store initial root sum for P&L calculation
        market.initialRootSum = rootSum;

        emit MarketCreated(marketId);
    }

    function settleMarket(uint256 marketId) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);
        if (market.failed) revert CE.MarketAlreadyFailed(marketId);

        SettlementOracleState storage state = settlementOracleState[marketId];
        if (state.candidatePriceTimestamp == 0) revert CE.SettlementOracleCandidateMissing();

        // Tset = settlementTimestamp (market creation time parameter)
        // startTimestamp < endTimestamp < settlementTimestamp
        uint64 tSet = market.settlementTimestamp;
        
        // Can only settle after Tset
        if (uint64(block.timestamp) < tSet) {
            revert CE.SettlementTooEarly(tSet, uint64(block.timestamp));
        }
        
        // Candidate must be from valid window [Tset, Tset + submitWindow]
        if (state.candidatePriceTimestamp < tSet) {
            revert CE.SettlementTooEarly(tSet, state.candidatePriceTimestamp);
        }
        if (state.candidatePriceTimestamp > tSet + settlementSubmitWindow) {
            revert CE.SettlementFinalizeWindowClosed(tSet + settlementSubmitWindow, state.candidatePriceTimestamp);
        }

        // Must finalize within deadline from candidate submission
        uint64 finalizeDeadlineTs = state.candidatePriceTimestamp + settlementFinalizeDeadline;
        if (uint64(block.timestamp) > finalizeDeadlineTs) {
            revert CE.SettlementFinalizeWindowClosed(finalizeDeadlineTs, uint64(block.timestamp));
        }

        int256 settlementTick = _toSettlementTick(market, state.candidateValue);

        market.settled = true;
        market.settlementValue = state.candidateValue;
        market.settlementTick = settlementTick;
        // settlementTimestamp stays as-is (market day key set at creation)
        // settlementFinalizedAt records when settlement tx was mined
        market.settlementFinalizedAt = uint64(block.timestamp);
        market.isActive = false;
        market.snapshotChunkCursor = 0;
        market.snapshotChunksDone = (market.openPositionCount == 0);

        // clear oracle candidate after use
        state.candidateValue = 0;
        state.candidatePriceTimestamp = 0;

        // Phase 6: Calculate P&L with payout reserve
        uint64 batchId = _getBatchIdForMarket(marketId);
        (int256 lt, uint256 ftot, uint256 payoutReserve) = _calculateMarketPnlWithPayout(marketId, settlementTick);
        
        // Store payout reserve in escrow (WP v2 Sec 3.3)
        // N_t already reflects payout reserve as deducted liability
        _payoutReserve[marketId] = payoutReserve;
        _payoutReserveRemaining[marketId] = payoutReserve;
        
        // Track total payout reserve for free balance calculation
        _totalPayoutReserve6 += payoutReserve;
        
        _recordPnlToBatch(batchId, lt, ftot);
        
        emit MarketPnlRecorded(marketId, batchId, lt, ftot);
        emit MarketSettled(marketId, market.settlementValue, settlementTick, market.settlementFinalizedAt);
    }

    /**
     * @notice Mark a market as failed due to oracle not providing valid settlement
     * @dev Can only be called after settlement window expires without valid candidate
     * @param marketId Market to mark as failed
     */
    function markFailed(uint256 marketId) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);
        if (market.failed) revert CE.MarketAlreadyFailed(marketId);

        // Tset = settlementTimestamp
        uint64 tSet = market.settlementTimestamp;
        uint64 deadline = tSet + settlementSubmitWindow + settlementFinalizeDeadline;

        // Can only mark failed after full settlement window has expired
        if (uint64(block.timestamp) <= deadline) {
            revert CE.SettlementWindowNotExpired(deadline, uint64(block.timestamp));
        }

        // Check if there's no valid candidate OR candidate expired
        SettlementOracleState storage state = settlementOracleState[marketId];
        bool hasValidCandidate = state.candidatePriceTimestamp != 0 &&
            state.candidatePriceTimestamp >= tSet &&
            state.candidatePriceTimestamp <= tSet + settlementSubmitWindow;

        if (hasValidCandidate) {
            // There's a valid candidate - should use settleMarket instead
            revert CE.SettlementOracleCandidateMissing(); // Misleading but indicates "use settleMarket"
        }

        market.failed = true;
        market.isActive = false;

        emit MarketFailed(marketId, uint64(block.timestamp));
    }

    /**
     * @notice Manually settle a failed market (secondary settlement path)
     * @dev Can only be called on a failed market. Ops provides settlement value.
     * @param marketId Market to settle
     * @param settlementValue The settlement value (ops-determined)
     */
    function manualSettleFailedMarket(
        uint256 marketId,
        int256 settlementValue
    ) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);
        if (!market.failed) revert CE.MarketNotFailed(marketId);

        int256 settlementTick = _toSettlementTick(market, settlementValue);

        market.settled = true;
        market.settlementValue = settlementValue;
        market.settlementTick = settlementTick;
        market.settlementTimestamp = market.endTimestamp; // Market day key
        market.settlementFinalizedAt = uint64(block.timestamp);
        market.snapshotChunkCursor = 0;
        market.snapshotChunksDone = (market.openPositionCount == 0);

        // Phase 6: Calculate P&L with payout reserve (same as primary settlement)
        uint64 batchId = _getBatchIdForMarket(marketId);
        (int256 lt, uint256 ftot, uint256 payoutReserve) = _calculateMarketPnlWithPayout(marketId, settlementTick);
        
        // Store payout reserve in escrow (WP v2 Sec 3.3)
        _payoutReserve[marketId] = payoutReserve;
        _payoutReserveRemaining[marketId] = payoutReserve;
        
        // Track total payout reserve for free balance calculation
        _totalPayoutReserve6 += payoutReserve;
        
        _recordPnlToBatch(batchId, lt, ftot);

        emit MarketPnlRecorded(marketId, batchId, lt, ftot);
        emit MarketSettledSecondary(marketId, settlementValue, settlementTick, market.settlementFinalizedAt);
    }

    function reopenMarket(uint256 marketId) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        // Can reopen either settled or failed markets
        if (!market.settled && !market.failed) revert CE.MarketNotSettled(marketId);

        market.settled = false;
        market.failed = false;
        market.settlementValue = 0;
        market.settlementTick = 0;
        market.settlementTimestamp = 0;
        market.settlementFinalizedAt = 0;
        market.isActive = true;
        market.snapshotChunkCursor = 0;
        market.snapshotChunksDone = false;

        settlementOracleState[marketId] = SettlementOracleState({candidateValue: 0, candidatePriceTimestamp: 0});
        emit MarketReopened(marketId);
    }

    function setMarketActive(uint256 marketId, bool isActive) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (isActive && market.settled) revert CE.MarketAlreadySettled(marketId);

        market.isActive = isActive;
        emit MarketActivationUpdated(marketId, isActive);
    }

    function updateMarketTiming(
        uint256 marketId,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp
    ) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);
        _validateTimeRange(startTimestamp, endTimestamp, settlementTimestamp);

        market.startTimestamp = startTimestamp;
        market.endTimestamp = endTimestamp;
        market.settlementTimestamp = settlementTimestamp;

        emit MarketTimingUpdated(marketId, startTimestamp, endTimestamp, settlementTimestamp);
    }

    function requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx) external onlyDelegated returns (uint32 emitted) {
        if (maxChunksPerTx == 0) revert CE.ZeroLimit();
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (!market.settled) revert CE.MarketNotSettled(marketId);
        if (market.snapshotChunksDone) revert CE.SnapshotAlreadyCompleted();

        uint32 totalChunks = _calculateTotalChunks(market.openPositionCount);
        uint32 cursor = market.snapshotChunkCursor;
        if (totalChunks == 0) {
            market.snapshotChunksDone = true;
            return 0;
        }

        while (cursor < totalChunks && emitted < maxChunksPerTx) {
            emit SettlementChunkRequested(marketId, cursor);
            cursor++;
            emitted++;
        }

        market.snapshotChunkCursor = cursor;
        if (cursor >= totalChunks) {
            market.snapshotChunksDone = true;
        }
    }

    // --- Internal helpers ---

    function _validateMarketParams(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp
    ) internal pure {
        if (tickSpacing <= 0) revert CE.InvalidMarketParameters(minTick, maxTick, tickSpacing);
        if (minTick >= maxTick) revert CE.InvalidMarketParameters(minTick, maxTick, tickSpacing);
        if ((maxTick - minTick) % tickSpacing != 0) revert CE.InvalidMarketParameters(minTick, maxTick, tickSpacing);
        _validateTimeRange(startTimestamp, endTimestamp, settlementTimestamp);
    }

    function _validateTimeRange(uint64 startTimestamp, uint64 endTimestamp, uint64 settlementTimestamp) internal pure {
        if (startTimestamp >= endTimestamp || endTimestamp > settlementTimestamp) {
            revert CE.InvalidTimeRange(startTimestamp, endTimestamp, settlementTimestamp);
        }
    }

    function _marketExists(uint256 marketId) internal view returns (bool) {
        return markets[marketId].numBins > 0;
    }

    function _toSettlementTick(ISignalsCore.Market memory market, int256 settlementValue) internal pure returns (int256) {
        int256 spacing = market.tickSpacing;
        int256 tick = settlementValue;
        if (tick < market.minTick) tick = market.minTick;
        if (tick > market.maxTick) tick = market.maxTick;
        int256 offset = tick - market.minTick;
        tick = market.minTick + (offset / spacing) * spacing;
        return tick;
    }

    function _calculateTotalChunks(uint32 openPositionCount) internal pure returns (uint32) {
        if (openPositionCount == 0) return 0;
        return (openPositionCount + CHUNK_SIZE - 1) / CHUNK_SIZE;
    }

    // ============================================================
    // Phase 6: P&L Recording
    // ============================================================

    /**
     * @notice Get batch ID for a market (based on settlement date)
     * @dev Uses market's settlement timestamp truncated to day
     * @param marketId Market identifier
     * @return batchId Batch identifier (day-based)
     */
    function _getBatchIdForMarket(uint256 marketId) internal view returns (uint64) {
        ISignalsCore.Market storage market = markets[marketId];
        // Use settlement timestamp divided by day (BATCH_SECONDS)
        // This groups all markets settling on the same day into one batch (day-key)
        return market.settlementTimestamp / BATCH_SECONDS;
    }

    /**
     * @notice Calculate market P&L from CLMSR tree state
     * @dev Phase 6: Calculates P&L using whitepaper formula:
     *      L_t = C(q_end) - C(q_start) = α * (ln(Z_end) - ln(Z_start))
     * 
     *      Where:
     *      - Z_start = initialRootSum (stored at market creation)
     *      - Z_end = current tree root sum
     *      - α = liquidityParameter
     * 
     *      P&L interpretation:
     *      - Positive: maker loss (Z_end > Z_start, traders net profitable)
     *      - Negative: maker profit (Z_end < Z_start, traders net losing)
     * 
     * @param marketId Market identifier
     * @return lt Maker P&L (signed: positive = loss, negative = profit)
     * @return ftot Gross fees collected during trading
     */
    function _calculateMarketPnl(uint256 marketId) internal view returns (int256 lt, uint256 ftot) {
        ISignalsCore.Market storage market = markets[marketId];
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        
        uint256 alpha = market.liquidityParameter;
        uint256 zStart = market.initialRootSum;
        
        // Get current root sum (Z_end)
        uint256 zEnd = tree.getRangeSum(0, market.numBins - 1);
        
        // P&L = α * (ln(Z_end) - ln(Z_start))
        // Per whitepaper Sec 3.5: L_t = C(q_end) - C(q_start)
        // where C(q) = α * ln(Z(q))
        // L_t > 0: cost increased → maker profit (traders net bought)
        // L_t < 0: cost decreased → maker loss (traders net sold)
        uint256 lnZEnd = zEnd.wLn();
        uint256 lnZStart = zStart.wLn();
        
        if (lnZEnd >= lnZStart) {
            // Maker profit: Z increased (cost increased, traders net bought)
            lt = int256(alpha.wMul(lnZEnd - lnZStart));
        } else {
            // Maker loss: Z decreased (cost decreased, traders net sold)
            lt = -int256(alpha.wMul(lnZStart - lnZEnd));
        }
        
        ftot = market.accumulatedFees;
    }

    /**
     * @notice Calculate market P&L with payout reserve deduction
     * @dev Phase 6: Whitepaper v2 formula:
     *      Payout_t := Q_{t,τ_t} (settlement tick exposure)
     *      L_t := ΔC_t - Payout_t (maker P&L net of payout)
     * 
     * @param marketId Market identifier
     * @param settlementTick The settlement tick τ_t
     * @return lt Maker P&L after payout deduction
     * @return ftot Gross fees collected during trading
     * @return payoutReserve Payout reserve Q_{τ_t} to be escrowed
     */
    function _calculateMarketPnlWithPayout(
        uint256 marketId,
        int256 settlementTick
    ) internal view returns (int256 lt, uint256 ftot, uint256 payoutReserve) {
        ISignalsCore.Market storage market = markets[marketId];
        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        
        uint256 alpha = market.liquidityParameter;
        uint256 zStart = market.initialRootSum;
        
        // Get current root sum (Z_end)
        uint256 zEnd = tree.getRangeSum(0, market.numBins - 1);
        
        // ΔC_t = α * (ln(Z_end) - ln(Z_start))
        // Per whitepaper Sec 3.5: ΔC_t = C(q_end) - C(q_start)
        int256 deltaC;
        uint256 lnZEnd = zEnd.wLn();
        uint256 lnZStart = zStart.wLn();
        
        if (lnZEnd >= lnZStart) {
            // Maker profit: Z increased (cost increased, traders net bought)
            deltaC = int256(alpha.wMul(lnZEnd - lnZStart));
        } else {
            // Maker loss: Z decreased (cost decreased, traders net sold)
            deltaC = -int256(alpha.wMul(lnZStart - lnZEnd));
        }
        
        // Payout_t := Q_{t,τ_t} (WP v2 Eq. 3.11)
        // Get payout exposure at settlement tick (token units, convert to WAD)
        payoutReserve = _exposureLedger[marketId][settlementTick];
        
        // L_t := ΔC_t - Payout_t (WP v2 Eq. 3.12)
        // Note: payoutReserve is in token units (6 decimals), need to convert to WAD for consistency
        // However, positions use quantity in token units, so payout is also in token units
        // For internal accounting consistency, we keep payoutReserve in token units
        // but L_t must be in WAD, so convert payoutReserve to WAD for subtraction
        uint256 payoutReserveWad = payoutReserve * 1e12; // USDC6 to WAD (1e6 → 1e18)
        
        lt = deltaC - int256(payoutReserveWad);
        
        ftot = market.accumulatedFees;
    }

    /**
     * @notice Record P&L to daily batch
     * @param batchId Batch identifier
     * @param lt P&L to add
     * @param ftot Fees to add
     */
    function _recordPnlToBatch(uint64 batchId, int256 lt, uint256 ftot) internal {
        DailyPnlSnapshot storage snap = _dailyPnl[batchId];
        if (snap.processed) revert CE.BatchAlreadyProcessed(batchId);
        snap.Lt += lt;
        snap.Ftot += ftot;
    }

    /**
     * @notice Manually record P&L for a batch (admin/testing)
     * @dev Allows external P&L recording for testing or when trades
     *      are processed off-chain
     * @param batchId Batch identifier
     * @param lt P&L to add
     * @param ftot Fees to add
     */
    function recordBatchPnl(uint64 batchId, int256 lt, uint256 ftot) external onlyDelegated {
        _recordPnlToBatch(batchId, lt, ftot);
        emit MarketPnlRecorded(0, batchId, lt, ftot);
    }

    // ============================================================
    // Phase 7: α Safety Enforcement
    // ============================================================

    /**
     * @notice Validate α against safety limit for market creation
     * @dev Per WP v2 Sec 4.5: α ≤ αlimit where αlimit depends on NAV and drawdown
     *      
     *      SAFETY: Uses lnWadUp for conservative α_base calculation.
     *      Over-estimating ln(n) → under-estimating α_base → safer bounds.
     *
     * @param liquidityParameter Market α to validate
     * @param numBins Number of outcome bins for the market
     */
    function _validateAlphaForMarket(uint256 liquidityParameter, uint32 numBins) internal view {
        if (!riskConfig.enforceAlpha) return; // Skip if not enforced
        if (lpVault.nav == 0) return; // Skip if vault not seeded
        
        // Calculate αbase = λ * E_t / ln(n) with safe (upward-rounded) ln
        uint256 lnN = FixedPointMathU.lnWadUp(numBins);
        if (lnN == 0) return; // Edge case: n <= 1
        
        uint256 alphaBase = riskConfig.lambda.wMul(lpVault.nav).wDiv(lnN);
        
        // Calculate drawdown: DD = 1 - P / P^peak
        uint256 drawdown = 0;
        if (lpVault.pricePeak > 0 && lpVault.price < lpVault.pricePeak) {
            drawdown = WAD - lpVault.price.wDiv(lpVault.pricePeak);
        }
        
        // Calculate αlimit = max{0, αbase * (1 - k * DD)}
        uint256 kDD = riskConfig.kDrawdown.wMul(drawdown);
        uint256 alphaLimit = kDD >= WAD ? 0 : alphaBase.wMul(WAD - kDD);
        
        if (liquidityParameter > alphaLimit) {
            revert CE.AlphaExceedsLimit(liquidityParameter, alphaLimit);
        }
    }

    // ============================================================
    // Phase 7: ΔEₜ Calculation and Prior Admissibility
    // ============================================================

    /**
     * @notice Calculate ΔEₜ (tail budget) from prior factors
     * @dev Per WP v2 Sec 4.1:
     *      E_ent(q₀,t) = C(q₀,t) - min_j q₀,t,j
     *      where q_b = α * ln(factor_b), C(q) = α * ln(rootSum)
     *      
     *      For general prior:
     *        E_ent = α * ln(rootSum) - α * ln(minFactor) = α * ln(rootSum/minFactor)
     *      
     *      ΔEₜ = E_ent - α*ln(n) = α * ln(rootSum / (n * minFactor))
     *      
     *      Uniform prior (all factors = 1 WAD):
     *        rootSum = n * WAD, minFactor = WAD → ΔEₜ = 0
     *
     * @param alpha Market liquidity parameter α (WAD)
     * @param numBins Number of outcome bins n
     * @param rootSum Sum of all factors (WAD)
     * @param minFactor Minimum factor value (WAD)
     * @return deltaEt Tail budget (WAD)
     */
    function _calculateDeltaEt(
        uint256 alpha,
        uint32 numBins,
        uint256 rootSum,
        uint256 minFactor
    ) internal pure returns (uint256 deltaEt) {
        // ΔEₜ = α * ln(rootSum / (n * minFactor))
        // If rootSum == n * minFactor (uniform), ΔEₜ = 0
        
        uint256 uniformSum = uint256(numBins) * minFactor;
        
        if (rootSum <= uniformSum) {
            // Uniform or near-uniform prior → no tail risk
            return 0;
        }
        
        // ΔEₜ = α * ln(rootSum / uniformSum)
        // Using: ln(a/b) = ln(a) - ln(b), and wLn for WAD-scaled log
        // For safety, we compute conservatively
        
        // ratio = rootSum / uniformSum (in WAD)
        uint256 ratio = rootSum.wDiv(uniformSum);
        
        // ln(ratio) where ratio > 1 WAD
        uint256 lnRatio = FixedPointMathU.wLn(ratio);
        
        // ΔEₜ = α * lnRatio
        deltaEt = alpha.wMul(lnRatio);
    }

    /**
     * @notice Validate prior admissibility
     * @dev Per WP v2: ΔEₜ ≤ B_eff_{t-1} ≤ backstopNav
     *      If violated, revert with PriorNotAdmissible
     * @param deltaEt Calculated tail budget (WAD)
     */
    function _validatePriorAdmissibility(uint256 deltaEt) internal view {
        // B_eff = backstopNav (simplified; full version would account for pending grants)
        uint256 effectiveBackstop = capitalStack.backstopNav;
        
        if (deltaEt > effectiveBackstop) {
            revert CE.PriorNotAdmissible(deltaEt, effectiveBackstop);
        }
    }
}
