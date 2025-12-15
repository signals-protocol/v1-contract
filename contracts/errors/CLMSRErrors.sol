// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Error set (ported from v0) shared across modules and math/tree libraries.
interface CLMSRErrors {
    /* Market lifecycle */
    error MarketNotStarted();
    error MarketExpired();
    error MarketNotActive();
    error MarketNotSettled(uint256 marketId);
    error MarketNotFound(uint256 marketId);
    error MarketAlreadySettled(uint256 marketId);
    error MarketAlreadyExists(uint256 marketId);
    error SettlementTooEarly(uint64 requiredTimestamp, uint64 currentTimestamp);
    error SettlementFinalizeWindowClosed(uint64 requiredTimestamp, uint64 currentTimestamp);
    error SettlementOracleCandidateMissing();
    error SettlementOracleSignatureInvalid(address signer);
    error MarketNotFailed(uint256 marketId);
    error MarketAlreadyFailed(uint256 marketId);
    error SettlementWindowNotExpired(uint64 deadline, uint64 currentTime);
    error BatchAlreadyProcessed(uint64 batchId);
    error BatchNotProcessed(uint64 batchId);

    /* Trade params */
    error InvalidTick(int256 tick, int256 minTick, int256 maxTick);
    error InvalidTickRange(int256 lowerTick, int256 upperTick);
    error InvalidTickSpacing(int256 tick, int256 tickSpacing);
    error InvalidQuantity(uint128 qty);
    error CostExceedsMaximum(uint256 cost, uint256 maxAllowed);
    error FeeExceedsBase(uint256 fee, uint256 baseAmount);
    error InvalidFeePolicy(address policy);
    error InvalidMarketParameters(int256 minTick, int256 maxTick, int256 tickSpacing);
    error InvalidTimeRange(uint64 start, uint64 end, uint64 settlement);

    /* Access control */
    error UnauthorizedCaller(address caller);

    /* Config / misc */
    error ZeroAddress();
    error InvalidTokenDecimals(uint8 provided, uint8 expected);
    error BinCountExceedsLimit(uint32 requested, uint32 maxAllowed);
    error InvalidLiquidityParameter();
    error ZeroLimit();
    error InvalidRangeCount(int256 ranges, uint256 maxAllowed);
    error RangeBinOutOfBounds(int256 bin, uint32 numBins);
    error BinOutOfBounds(uint32 bin, uint32 numBins);
    error RangeBinsOutOfBounds(uint32 lowerBin, uint32 upperBin, uint32 numBins);
    error InvalidRangeBins(uint32 lowerBin, uint32 upperBin);
    error ManagerNotSet();
    error SnapshotAlreadyCompleted();

    /* Position */
    error PositionNotFound(uint256 positionId);
    error InsufficientBalance(address account, uint256 required, uint256 available);
    
    /* Free balance / Escrow safety (Phase 6) */
    error InsufficientFreeBalance(uint256 requested, uint256 available);
    
    /* Risk / α Safety (Phase 7) */
    error AlphaExceedsLimit(uint256 marketAlpha, uint256 alphaLimit);

    /* Trade / math */
    error MathMulOverflow();
    error NonIncreasingSum(uint256 beforeSum, uint256 afterSum);
    error SumAfterZero();
    error NoChunkProgress();
    error ResidualQuantity(uint256 remaining);
    error AffectedSumZero();
    error ChunkLimitExceeded(uint256 required, uint256 maxAllowed);
    error QuantityOverflow();
    error InsufficientPositionQuantity(uint128 want, uint128 have);
    error ProceedsBelowMinimum(uint256 proceeds, uint256 minProceeds);
    error CloseInconsistent(uint128 expectedZero, uint128 actual);

    /* Tree */
    error TreeNotInitialized();
    error TreeSizeZero();
    error TreeSizeTooLarge();
    error TreeAlreadyInitialized();
    error LazyFactorOverflow();
    error ArrayLengthMismatch();
    error InvalidFactor(uint256 factor);
    error IndexOutOfBounds(uint32 index, uint32 size);
    error InvalidRange(uint32 lo, uint32 hi);
}

/// @notice Alias for ease of import parity with v0.
library CE {
    /* Market lifecycle */
    error MarketNotStarted();
    error MarketExpired();
    error MarketNotActive();
    error MarketNotSettled(uint256 marketId);
    error MarketNotFound(uint256 marketId);
    error MarketAlreadySettled(uint256 marketId);
    error MarketAlreadyExists(uint256 marketId);
    error SettlementTooEarly(uint64 requiredTimestamp, uint64 currentTimestamp);
    error SettlementFinalizeWindowClosed(uint64 requiredTimestamp, uint64 currentTimestamp);
    error SettlementOracleCandidateMissing();
    error SettlementOracleSignatureInvalid(address signer);
    error MarketNotFailed(uint256 marketId);
    error MarketAlreadyFailed(uint256 marketId);
    error SettlementWindowNotExpired(uint64 deadline, uint64 currentTime);
    error BatchAlreadyProcessed(uint64 batchId);
    error BatchNotProcessed(uint64 batchId);

    /* Trade params */
    error InvalidTick(int256 tick, int256 minTick, int256 maxTick);
    error InvalidTickRange(int256 lowerTick, int256 upperTick);
    error InvalidTickSpacing(int256 tick, int256 tickSpacing);
    error InvalidQuantity(uint128 qty);
    error CostExceedsMaximum(uint256 cost, uint256 maxAllowed);
    error FeeExceedsBase(uint256 fee, uint256 baseAmount);
    error InvalidFeePolicy(address policy);
    error InvalidMarketParameters(int256 minTick, int256 maxTick, int256 tickSpacing);
    error InvalidTimeRange(uint64 start, uint64 end, uint64 settlement);

    /* Access control */
    error UnauthorizedCaller(address caller);

    /* Config / misc */
    error ZeroAddress();
    error InvalidTokenDecimals(uint8 provided, uint8 expected);
    error BinCountExceedsLimit(uint32 requested, uint32 maxAllowed);
    error InvalidLiquidityParameter();
    error ZeroLimit();
    error InvalidRangeCount(int256 ranges, uint256 maxAllowed);
    error RangeBinOutOfBounds(int256 bin, uint32 numBins);
    error BinOutOfBounds(uint32 bin, uint32 numBins);
    error RangeBinsOutOfBounds(uint32 lowerBin, uint32 upperBin, uint32 numBins);
    error InvalidRangeBins(uint32 lowerBin, uint32 upperBin);
    error ManagerNotSet();
    error SnapshotAlreadyCompleted();

    /* Position */
    error PositionNotFound(uint256 positionId);
    error InsufficientBalance(address account, uint256 required, uint256 available);
    
    /* Free balance / Escrow safety (Phase 6) */
    error InsufficientFreeBalance(uint256 requested, uint256 available);
    
    /* Risk / α Safety (Phase 7) */
    error AlphaExceedsLimit(uint256 marketAlpha, uint256 alphaLimit);

    /* Trade / math */
    error MathMulOverflow();
    error NonIncreasingSum(uint256 beforeSum, uint256 afterSum);
    error SumAfterZero();
    error NoChunkProgress();
    error ResidualQuantity(uint256 remaining);
    error AffectedSumZero();
    error ChunkLimitExceeded(uint256 required, uint256 maxAllowed);
    error QuantityOverflow();
    error InsufficientPositionQuantity(uint128 want, uint128 have);
    error ProceedsBelowMinimum(uint256 proceeds, uint256 minProceeds);
    error CloseInconsistent(uint128 expectedZero, uint128 actual);

    /* Tree */
    error TreeNotInitialized();
    error TreeSizeZero();
    error TreeSizeTooLarge();
    error TreeAlreadyInitialized();
    error LazyFactorOverflow();
    error ArrayLengthMismatch();
    error InvalidFactor(uint256 factor);
    error IndexOutOfBounds(uint32 index, uint32 size);
    error InvalidRange(uint32 lo, uint32 hi);
}
