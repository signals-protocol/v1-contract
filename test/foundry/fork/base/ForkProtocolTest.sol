// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ForkBaseTest.sol";
import "../../base/SeedHelper.sol";

/// @title ForkProtocolTest
/// @notice Deterministic helper layer for fork tests that create their own markets and batches.
abstract contract ForkProtocolTest is ForkBaseTest {
    uint256 internal constant WAD = 1e18;
    uint64 internal constant BATCH_SECONDS = 86_400;
    uint64 internal constant BATCH_TIMEZONE_OFFSET = 28_800;

    IERC20 internal payment;
    address internal forkOperator;

    function setUp() public virtual override {
        super.setUp();
        payment = IERC20(paymentToken);
    }

    function _fundAndApprove(address user, uint256 amount6) internal {
        deal(paymentToken, user, amount6);
        vm.prank(user);
        payment.approve(address(core), type(uint256).max);
    }

    function _ensureForkOperator() internal returns (address operator) {
        if (forkOperator == address(0)) {
            forkOperator = makeAddr("forkOperator");
            vm.prank(ownerSafe);
            core.setOperator(forkOperator, true);
        }
        return forkOperator;
    }

    function _toBatchId(uint64 timestamp) internal pure returns (uint64) {
        if (timestamp < BATCH_TIMEZONE_OFFSET) {
            return 0;
        }
        return (timestamp - BATCH_TIMEZONE_OFFSET) / BATCH_SECONDS;
    }

    function _batchStartTimestamp(uint64 batchId) internal pure returns (uint64) {
        return batchId * BATCH_SECONDS + BATCH_TIMEZONE_OFFSET;
    }

    function _batchEndTimestamp(uint64 batchId) internal pure returns (uint64) {
        return _batchStartTimestamp(batchId + 1);
    }

    function _targetBatchAfter(uint64 minTimestamp) internal view returns (uint64 targetBatch) {
        uint64 nextBatch = core.getCurrentBatchId() + 1;
        uint64 futureBatch = _toBatchId(minTimestamp);
        return futureBatch > nextBatch ? futureBatch : nextBatch;
    }

    function _warpIntoTradingWindow(uint256 marketId) internal {
        ISignalsCore.Market memory market = core.getMarket(marketId);
        if (block.timestamp < market.startTimestamp) {
            vm.warp(uint256(market.startTimestamp) + 1);
        }
    }

    function _defaultFeePolicy() internal view returns (address) {
        address feePolicy = _tryContractAddr("FeePolicy10bps");
        if (feePolicy == address(0)) {
            feePolicy = _contractAddr("FeePolicyNull");
        }
        return feePolicy;
    }

    function _btcOracleConfig() internal pure returns (ISignalsCore.MarketOracleConfig memory) {
        return ISignalsCore.MarketOracleConfig({feedId: bytes32("BTC"), feedDecimals: 8, tickScale: 1_000_000});
    }

    function _deployUniformSeedData(uint32 numBins) internal returns (address) {
        uint256[] memory factors = new uint256[](numBins);
        for (uint32 i = 0; i < numBins; i++) {
            factors[i] = WAD;
        }
        return address(SeedHelper.deploySeedData(factors));
    }

    function _deployConcentratedSeedData(uint32 numBins, uint256 edgeFactor) internal returns (address) {
        uint256[] memory factors = new uint256[](numBins);
        for (uint32 i = 0; i < numBins; i++) {
            factors[i] = WAD;
        }
        factors[0] = edgeFactor;
        return address(SeedHelper.deploySeedData(factors));
    }

    function _createUniformMarketForBatch(uint64 batchId) internal returns (uint256 marketId) {
        uint64 minSettle = uint64(block.timestamp + 120);
        uint64 batchStart = _batchStartTimestamp(batchId);
        uint64 settlementTimestamp = minSettle > batchStart + 600 ? minSettle : batchStart + 600;
        require(_toBatchId(settlementTimestamp) == batchId, "fork batch mismatch");

        uint64 endTimestamp = settlementTimestamp - 30;
        uint64 startTimestamp = endTimestamp - 30;
        if (startTimestamp >= endTimestamp) {
            startTimestamp = endTimestamp - 1;
        }

        address seedData = _deployUniformSeedData(4);
        vm.prank(ownerSafe);
        marketId = core.createMarket(
            0,
            4,
            1,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            4,
            WAD,
            _defaultFeePolicy(),
            seedData,
            _btcOracleConfig()
        );
        vm.prank(ownerSafe);
        core.seedNextChunks(marketId, 4);
    }

    function _createConcentratedMarketForBatch(uint64 batchId, uint32 numBins, uint256 alpha, uint256 edgeFactor)
        internal
        returns (uint256 marketId)
    {
        uint64 minSettle = uint64(block.timestamp + 120);
        uint64 batchStart = _batchStartTimestamp(batchId);
        uint64 settlementTimestamp = minSettle > batchStart + 600 ? minSettle : batchStart + 600;
        require(_toBatchId(settlementTimestamp) == batchId, "fork batch mismatch");

        uint64 endTimestamp = settlementTimestamp - 30;
        uint64 startTimestamp = endTimestamp - 30;
        if (startTimestamp >= endTimestamp) {
            startTimestamp = endTimestamp - 1;
        }

        address seedData = _deployConcentratedSeedData(numBins, edgeFactor);
        vm.prank(ownerSafe);
        marketId = core.createMarket(
            0,
            int256(uint256(numBins)),
            1,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            numBins,
            alpha,
            _defaultFeePolicy(),
            seedData,
            _btcOracleConfig()
        );
        vm.prank(ownerSafe);
        core.seedNextChunks(marketId, numBins);
    }

    function _secondarySettleAndSnapshot(uint256 marketId, int256 settlementValue, uint32 maxChunksPerTx)
        internal
        returns (uint64 batchId)
    {
        ISignalsCore.Market memory market = core.getMarket(marketId);
        vm.warp(uint256(market.settlementTimestamp) + core.settlementSubmitWindow() + 1);

        vm.startPrank(ownerSafe);
        core.markSettlementFailed(marketId);
        core.finalizeSecondarySettlement(marketId, settlementValue);
        core.requestSettlementChunks(marketId, maxChunksPerTx);
        vm.stopPrank();

        return _toBatchId(market.settlementTimestamp);
    }

    function _fallbackSettlementValue(ISignalsCore.Market memory market) internal pure returns (int256) {
        int256 midpointTick = market.minTick + (int256(uint256(market.numBins / 2)) * market.tickSpacing);
        int256 lastValidTick = market.maxTick - market.tickSpacing;
        if (midpointTick > lastValidTick) {
            midpointTick = lastValidTick;
        }
        return midpointTick * int256(uint256(market.tickScale));
    }

    function _resolveAmbientBatchMarkets(uint64 batchId) internal {
        (uint64 total, uint64 resolved) = core.getBatchMarketState(batchId);
        if (total == resolved) {
            return;
        }

        uint256 maxMarketId = core.nextMarketId();
        for (uint256 marketId = 1; marketId <= maxMarketId && resolved < total; marketId++) {
            ISignalsCore.Market memory market = core.getMarket(marketId);
            if (market.settled || _toBatchId(market.settlementTimestamp) != batchId) {
                continue;
            }

            uint64 opsStart = market.settlementTimestamp + core.settlementSubmitWindow();
            if (block.timestamp < opsStart) {
                vm.warp(uint256(opsStart) + 1);
            }

            vm.startPrank(ownerSafe);
            if (market.failed) {
                core.finalizeSecondarySettlement(marketId, _fallbackSettlementValue(market));
            } else {
                try core.finalizePrimarySettlement(marketId) {}
                catch {
                    core.markSettlementFailed(marketId);
                    core.finalizeSecondarySettlement(marketId, _fallbackSettlementValue(market));
                }
            }
            vm.stopPrank();

            (total, resolved) = core.getBatchMarketState(batchId);
        }

        require(total == resolved, "fork baseline blocked by unresolved batch");
    }

    function _processBatchesThrough(uint64 targetBatch) internal {
        while (core.getCurrentBatchId() < targetBatch) {
            uint64 nextBatch = core.getCurrentBatchId() + 1;
            _resolveAmbientBatchMarkets(nextBatch);

            uint64 batchEnd = _batchEndTimestamp(nextBatch);
            if (block.timestamp <= batchEnd) {
                vm.warp(uint256(batchEnd) + 1);
            }

            vm.prank(ownerSafe);
            core.processDailyBatch(nextBatch);
        }
    }
}
