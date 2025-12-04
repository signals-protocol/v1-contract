// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../errors/ModuleErrors.sol";
import "../errors/CLMSRErrors.sol";
import "../lib/LazyMulSegmentTree.sol";

/// @notice Delegate-only lifecycle module (skeleton)
contract MarketLifecycleModule is SignalsCoreStorage {
    using LazyMulSegmentTree for LazyMulSegmentTree.Tree;

    address private immutable self;

    event SettlementChunkRequested(uint256 indexed marketId, uint32 indexed chunkIndex);
    event MarketCreated(uint256 indexed marketId);
    event MarketSettled(
        uint256 indexed marketId,
        int256 settlementValue,
        int256 settlementTick,
        uint64 settlementTimestamp
    );
    event MarketReopened(uint256 indexed marketId);
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

    function createMarket(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp,
        uint32 numBins,
        uint256 liquidityParameter,
        address feePolicy
    ) external onlyDelegated returns (uint256 marketId) {
        _validateMarketParams(minTick, maxTick, tickSpacing, startTimestamp, endTimestamp, settlementTimestamp);
        if (numBins == 0) revert CE.BinCountExceedsLimit(0, MAX_BIN_COUNT);
        if (numBins > MAX_BIN_COUNT) revert CE.BinCountExceedsLimit(numBins, MAX_BIN_COUNT);
        uint32 expectedBins = uint32(uint256((maxTick - minTick) / tickSpacing));
        if (expectedBins != numBins) revert CE.InvalidMarketParameters(minTick, maxTick, tickSpacing);
        if (liquidityParameter == 0) revert CE.InvalidLiquidityParameter();

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

        LazyMulSegmentTree.Tree storage tree = marketTrees[marketId];
        tree.init(numBins);
        uint256[] memory factors = new uint256[](numBins);
        for (uint256 i = 0; i < numBins; i++) {
            factors[i] = 1e18;
        }
        tree.seedWithFactors(factors);

        emit MarketCreated(marketId);
    }

    function settleMarket(uint256 marketId) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);

        SettlementOracleState storage state = settlementOracleState[marketId];
        if (state.candidatePriceTimestamp == 0) revert CE.SettlementOracleCandidateMissing();

        uint64 endTs = market.endTimestamp;
        if (uint64(block.timestamp) < endTs) {
            revert CE.SettlementTooEarly(endTs, uint64(block.timestamp));
        }
        if (state.candidatePriceTimestamp < endTs) {
            revert CE.SettlementTooEarly(endTs, state.candidatePriceTimestamp);
        }
        if (state.candidatePriceTimestamp > endTs + settlementSubmitWindow) {
            revert CE.SettlementFinalizeWindowClosed(endTs + settlementSubmitWindow, state.candidatePriceTimestamp);
        }

        uint64 finalizeDeadlineTs = state.candidatePriceTimestamp + settlementFinalizeDeadline;
        if (uint64(block.timestamp) > finalizeDeadlineTs) {
            revert CE.SettlementFinalizeWindowClosed(finalizeDeadlineTs, uint64(block.timestamp));
        }

        int256 settlementTick = _toSettlementTick(market, state.candidateValue);

        market.settled = true;
        market.settlementValue = state.candidateValue;
        market.settlementTick = settlementTick;
        market.settlementTimestamp = uint64(block.timestamp);
        market.isActive = false;
        market.snapshotChunkCursor = 0;
        market.snapshotChunksDone = (market.openPositionCount == 0);

        // clear oracle candidate after use
        state.candidateValue = 0;
        state.candidatePriceTimestamp = 0;

        emit MarketSettled(marketId, market.settlementValue, settlementTick, market.settlementTimestamp);
    }

    function reopenMarket(uint256 marketId) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (!_marketExists(marketId)) revert CE.MarketNotFound(marketId);
        if (!market.settled) revert CE.MarketNotSettled(marketId);

        market.settled = false;
        market.settlementValue = 0;
        market.settlementTick = 0;
        market.settlementTimestamp = 0;
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
}
