import hre from "hardhat";
import { loadEnvironment, normalizeEnvironment } from "../utils/environment";
import type { Environment } from "../types/environment";

// === Editable config (top-level) ============================================
const CONFIG = {
  marketId: 1,
  mode: "secondary", // "secondary" | "primary"
  settlement: {
    valueUsd: "85000", // 6 decimals, used when settlement.tick is empty
    tick: "", // if set, overrides valueUsd (settlementValue = tick * 1e6)
  },
  timing: {
    mode: "auto", // "auto" | "manual" | "skip"
    auto: {
      daysBack: 2, // move settlement into a past batch so processDailyBatch can run
      durationSec: 3600,
      endOffsetSec: 60,
    },
    manual: {
      startTimestamp: 0,
      endTimestamp: 0,
      settlementTimestamp: 0,
    },
  },
  chunks: {
    maxPerTx: 25,
    maxCalls: 20,
  },
  batch: {
    run: true,
  },
} as const;

// === Helpers ================================================================
const USD_DECIMALS = 6;
const BATCH_SECONDS = 86400n;

function usd6(value: string): bigint {
  return hre.ethers.parseUnits(value, USD_DECIMALS);
}

function resolveSettlementValue(): bigint {
  if (CONFIG.settlement.tick) {
    return BigInt(CONFIG.settlement.tick) * 1_000_000n;
  }
  return usd6(CONFIG.settlement.valueUsd);
}

function computeAutoTiming(now: number) {
  const settlementTimestamp = now - CONFIG.timing.auto.daysBack * Number(BATCH_SECONDS);
  const endTimestamp = settlementTimestamp - CONFIG.timing.auto.endOffsetSec;
  const startTimestamp = endTimestamp - CONFIG.timing.auto.durationSec;
  if (startTimestamp <= 0 || endTimestamp <= startTimestamp || endTimestamp > settlementTimestamp) {
    throw new Error("Invalid auto timing config");
  }
  return { startTimestamp, endTimestamp, settlementTimestamp };
}

async function main() {
  const { ethers, network } = hre;
  const env = normalizeEnvironment(network.name) as Environment;
  console.log(`[close-market] environment=${env} network=${network.name}`);

  const envData = loadEnvironment(env);
  const coreAddress = envData.contracts.SignalsCoreProxy;
  if (!coreAddress) throw new Error("Missing SignalsCoreProxy in environment file");

  const core = await ethers.getContractAt("SignalsCore", coreAddress);
  const marketId = CONFIG.marketId;

  let market = await core.markets(marketId);
  if (market.numBins === 0n) {
    throw new Error(`Market not found: ${marketId}`);
  }

  const latestBlock = await ethers.provider.getBlock("latest");
  const now = latestBlock?.timestamp ?? Math.floor(Date.now() / 1000);

  if (CONFIG.timing.mode !== "skip") {
    const timing =
      CONFIG.timing.mode === "manual"
        ? {
            startTimestamp: CONFIG.timing.manual.startTimestamp,
            endTimestamp: CONFIG.timing.manual.endTimestamp,
            settlementTimestamp: CONFIG.timing.manual.settlementTimestamp,
          }
        : computeAutoTiming(now);

    console.log(
      `[close-market] updateMarketTiming start=${timing.startTimestamp} end=${timing.endTimestamp} settle=${timing.settlementTimestamp}`
    );
    await (await core.updateMarketTiming(marketId, timing.startTimestamp, timing.endTimestamp, timing.settlementTimestamp)).wait();
    market = await core.markets(marketId);
  }

  if (!market.settled) {
    if (CONFIG.mode === "primary") {
      console.log("[close-market] finalizePrimarySettlement");
      await (await core.finalizePrimarySettlement(marketId)).wait();
    } else {
      if (!market.failed) {
        console.log("[close-market] markSettlementFailed");
        await (await core.markSettlementFailed(marketId)).wait();
      }
      const settlementValue = resolveSettlementValue();
      console.log(`[close-market] finalizeSecondarySettlement value=${settlementValue.toString()}`);
      await (await core.finalizeSecondarySettlement(marketId, settlementValue)).wait();
    }
    market = await core.markets(marketId);
  } else {
    console.log("[close-market] already settled (skip settlement)");
  }

  if (!market.snapshotChunksDone) {
    let calls = 0;
    while (!market.snapshotChunksDone && calls < CONFIG.chunks.maxCalls) {
      console.log(`[close-market] requestSettlementChunks call=${calls + 1}`);
      await (await core.requestSettlementChunks(marketId, CONFIG.chunks.maxPerTx)).wait();
      market = await core.markets(marketId);
      calls += 1;
    }
    if (!market.snapshotChunksDone) {
      console.warn("[close-market] snapshotChunksDone is still false (increase maxCalls?)");
    }
  } else {
    console.log("[close-market] snapshot chunks already done");
  }

  if (CONFIG.batch.run) {
    const batchId = BigInt(market.settlementTimestamp) / BATCH_SECONDS;
    const [total, resolved] = await core.getBatchMarketState(batchId);
    if (total === 0n) {
      console.warn(`[close-market] skip batch ${batchId.toString()} (no markets assigned)`);
      return;
    }
    if (resolved !== total) {
      console.warn(
        `[close-market] skip batch ${batchId.toString()} (resolved ${resolved.toString()}/${total.toString()})`
      );
      return;
    }
    try {
      console.log(`[close-market] processDailyBatch batchId=${batchId.toString()}`);
      await (await core.processDailyBatch(batchId)).wait();
    } catch (err) {
      console.warn("[close-market] processDailyBatch failed (batch not ready or not ended yet)");
      console.warn(err);
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
