// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISignalsCore {
    struct Market {
        // status flags (packable)
        bool isActive;
        bool settled;
        bool snapshotChunksDone;
        uint32 numBins;
        uint32 openPositionCount;
        uint32 snapshotChunkCursor;

        // timing
        uint64 startTimestamp;
        uint64 endTimestamp;
        uint64 settlementTimestamp;

        // ticks / math
        int256 minTick;
        int256 maxTick;
        int256 tickSpacing;
        int256 settlementTick;
        int256 settlementValue;
        uint256 liquidityParameter;

        // policy
        address feePolicy;
    }

    // Trade / lifecycle entrypoints (signatures preserved for parity)
    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external returns (uint256 positionId);

    function increasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 maxCost
    ) external;

    function decreasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 minProceeds
    ) external;

    function closePosition(
        uint256 positionId,
        uint256 minProceeds
    ) external;

    function claimPayout(uint256 positionId) external;

    // View helpers (v0 parity)
    function calculateOpenCost(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external view returns (uint256 cost);

    function calculateIncreaseCost(
        uint256 positionId,
        uint128 quantity
    ) external view returns (uint256 cost);

    function calculateDecreaseProceeds(
        uint256 positionId,
        uint128 quantity
    ) external view returns (uint256 proceeds);

    function calculateCloseProceeds(uint256 positionId) external view returns (uint256 proceeds);

    function calculatePositionValue(uint256 positionId) external view returns (uint256 value);

    // Lifecycle: settlement snapshot trigger
    function requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx) external returns (uint32 emitted);
}
