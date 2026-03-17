// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {ISignalsCore} from "../../contracts/interfaces/ISignalsCore.sol";
import {console} from "forge-std/console.sol";

/// @title CloseMarket — Multi-step market settlement
/// @notice Reads config from script/config/close-market-{env}.json
/// @dev Handles: updateMarketTiming, finalize/fail settlement, requestSettlementChunks,
///      and optional processDailyBatch
contract CloseMarket is BaseScript {
    uint256 internal constant BATCH_SECONDS = 86400;
    uint256 internal constant BATCH_TIMEZONE_OFFSET = 8 * 3600;

    function run() external {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        SignalsCore core = SignalsCore(coreProxy);

        string memory configPath = string.concat("script/config/close-market-", envName, ".json");
        string memory json = vm.readFile(configPath);

        uint256 marketId = vm.parseJsonUint(json, ".marketId");
        string memory mode = vm.parseJsonString(json, ".mode");

        // Verify market exists
        ISignalsCore.Market memory market = _getMarket(core, marketId);
        require(market.numBins > 0, "Market not found");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // ── Timing update ───────────────────────────────────────────────
        string memory timingMode = vm.parseJsonString(json, ".timing.mode");

        if (keccak256(bytes(timingMode)) != keccak256("skip")) {
            uint64 startTs;
            uint64 endTs;
            uint64 settlementTs;

            if (keccak256(bytes(timingMode)) == keccak256("manual")) {
                startTs = uint64(vm.parseJsonUint(json, ".timing.manual.startTimestamp"));
                endTs = uint64(vm.parseJsonUint(json, ".timing.manual.endTimestamp"));
                settlementTs = uint64(vm.parseJsonUint(json, ".timing.manual.settlementTimestamp"));
            } else {
                // Auto timing
                uint256 daysBack = vm.parseJsonUint(json, ".timing.auto.daysBack");
                uint256 durationSec = vm.parseJsonUint(json, ".timing.auto.durationSec");
                uint256 endOffsetSec = vm.parseJsonUint(json, ".timing.auto.endOffsetSec");

                settlementTs = uint64(block.timestamp - daysBack * BATCH_SECONDS);
                endTs = uint64(uint256(settlementTs) - endOffsetSec);
                startTs = uint64(uint256(endTs) - durationSec);
                require(startTs > 0 && endTs > startTs, "Invalid auto timing");
            }

            console.log(
                "[close-market] updateTiming start=%s end=%s settle=%s",
                uint256(startTs),
                uint256(endTs),
                uint256(settlementTs)
            );
            core.updateMarketTiming(marketId, startTs, endTs, settlementTs);
            market = _getMarket(core, marketId);
        }

        // ── Settlement ──────────────────────────────────────────────────
        if (!market.settled) {
            if (keccak256(bytes(mode)) == keccak256("primary")) {
                console.log("[close-market] finalizePrimarySettlement");
                core.finalizePrimarySettlement(marketId);
            } else {
                if (!market.failed) {
                    console.log("[close-market] markSettlementFailed");
                    core.markSettlementFailed(marketId);
                }

                int256 settlementValue;
                string memory tick = vm.parseJsonString(json, ".settlement.tick");
                if (bytes(tick).length > 0) {
                    settlementValue = int256(vm.parseJsonUint(json, ".settlement.tick")) * 1_000_000;
                } else {
                    settlementValue = int256(vm.parseJsonUint(json, ".settlement.valueUsd") * 1e6);
                }

                console.log("[close-market] finalizeSecondarySettlement");
                core.finalizeSecondarySettlement(marketId, settlementValue);
            }
            market = _getMarket(core, marketId);
        } else {
            console.log("[close-market] already settled");
        }

        // ── Settlement chunks ───────────────────────────────────────────
        if (!market.snapshotChunksDone) {
            uint32 maxPerTx = uint32(vm.parseJsonUint(json, ".chunks.maxPerTx"));
            uint256 maxCalls = vm.parseJsonUint(json, ".chunks.maxCalls");
            if (maxPerTx == 0) maxPerTx = 25;
            if (maxCalls == 0) maxCalls = 20;

            uint256 calls = 0;
            while (calls < maxCalls) {
                console.log("[close-market] requestSettlementChunks call=%s", calls + 1);
                core.requestSettlementChunks(marketId, maxPerTx);
                calls++;

                market = _getMarket(core, marketId);
                if (market.snapshotChunksDone) break;
            }
        }

        // ── Process daily batch ─────────────────────────────────────────
        bool runBatch = vm.parseJsonBool(json, ".batch.run");
        if (runBatch) {
            market = _getMarket(core, marketId);
            uint64 batchId = _toBatchId(market.settlementTimestamp);

            (uint64 total, uint64 resolved) = core.getBatchMarketState(batchId);

            if (total > 0 && resolved == total) {
                console.log("[close-market] processDailyBatch batchId=%s", uint256(batchId));
                core.processDailyBatch(batchId);
            } else {
                console.log(
                    "[close-market] skip batch %s (total=%s resolved=%s)",
                    uint256(batchId),
                    uint256(total),
                    uint256(resolved)
                );
            }
        }

        vm.stopBroadcast();
    }

    function _getMarket(SignalsCore core, uint256 marketId) internal view returns (ISignalsCore.Market memory m) {
        (
            m.isSeeded,
            m.settled,
            m.snapshotChunksDone,
            m.failed,
            m.numBins,
            m.openPositionCount,
            m.snapshotChunkCursor,
            m.seedCursor,
            m.startTimestamp,
            m.endTimestamp,
            m.settlementTimestamp,
            m.settlementFinalizedAt,
            m.minTick,
            m.maxTick,
            m.tickSpacing,
            m.settlementTick,
            m.settlementValue,
            m.liquidityParameter,
            m.feePolicy,
            m.seedData,
            m.initialRootSum,
            m.accumulatedFees,
            m.minFactor,
            m.deltaEt
        ) = core.markets(marketId);
    }

    function _toBatchId(uint64 timestamp) internal pure returns (uint64) {
        if (timestamp < BATCH_TIMEZONE_OFFSET) return 0;
        return uint64((uint256(timestamp) - BATCH_TIMEZONE_OFFSET) / BATCH_SECONDS);
    }
}
