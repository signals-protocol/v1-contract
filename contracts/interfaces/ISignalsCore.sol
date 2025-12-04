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
    ) external returns (uint256 cost);

    function calculateIncreaseCost(
        uint256 positionId,
        uint128 quantity
    ) external returns (uint256 cost);

    function calculateDecreaseProceeds(
        uint256 positionId,
        uint128 quantity
    ) external returns (uint256 proceeds);

    function calculateCloseProceeds(uint256 positionId) external returns (uint256 proceeds);

    function calculatePositionValue(uint256 positionId) external returns (uint256 value);

    // Lifecycle: settlement snapshot trigger
    function requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx) external returns (uint32 emitted);

    // Lifecycle / oracle admin
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
    ) external returns (uint256 marketId);

    function settleMarket(uint256 marketId) external;

    function reopenMarket(uint256 marketId) external;

    function setMarketActive(uint256 marketId, bool isActive) external;

    function updateMarketTiming(
        uint256 marketId,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp
    ) external;

    function submitSettlementPrice(
        uint256 marketId,
        int256 settlementValue,
        uint64 priceTimestamp,
        bytes calldata signature
    ) external;

    function setOracleConfig(address signer) external;

    function getSettlementPrice(uint256 marketId, uint256 timestamp)
        external
        returns (int256 price, uint64 priceTimestamp);
}
