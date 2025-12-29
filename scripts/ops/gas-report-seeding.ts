import { ethers } from "hardhat";
import { deployFullSystem } from "../../test/helpers/fullSystem";
import { deploySeedData } from "../../test/helpers/seed";
import { uniformFactors, WAD } from "../../test/helpers/constants";

const NUM_BINS = Number(process.env.NUM_BINS ?? "200");
const CHUNK_SIZE = Number(process.env.CHUNK_SIZE ?? "50");
const GAS_PRICE_GWEI = BigInt(process.env.GAS_PRICE_GWEI ?? "20");

function formatGas(label: string, gas: bigint) {
  console.log(`${label}: ${gas.toString()} gas`);
}

function formatCost(label: string, gas: bigint) {
  const wei = gas * GAS_PRICE_GWEI * 1_000_000_000n;
  console.log(`${label}: ${ethers.formatEther(wei)} ETH @ ${GAS_PRICE_GWEI} gwei`);
}

async function main() {
  if (NUM_BINS <= 0 || NUM_BINS > 256) {
    throw new Error(`NUM_BINS must be in (0, 256], got ${NUM_BINS}`);
  }
  if (CHUNK_SIZE <= 0) {
    throw new Error(`CHUNK_SIZE must be > 0, got ${CHUNK_SIZE}`);
  }

  const { core } = await deployFullSystem();

  const factors = uniformFactors(NUM_BINS);
  const seedData = await deploySeedData(factors);
  const seedDeployTx = seedData.deploymentTransaction();
  const seedDeployReceipt = seedDeployTx ? await seedDeployTx.wait() : null;
  const seedDeployGas = seedDeployReceipt?.gasUsed ?? 0n;

  const block = await ethers.provider.getBlock("latest");
  const now = Number(block?.timestamp ?? Math.floor(Date.now() / 1000));
  const startTimestamp = now - 10;
  const endTimestamp = now + 3600;
  const settlementTimestamp = endTimestamp + 3600;

  const beforeMarketId = await core.nextMarketId();
  const createTx = await core.createMarket(
    0,
    NUM_BINS,
    1,
    startTimestamp,
    endTimestamp,
    settlementTimestamp,
    NUM_BINS,
    WAD,
    ethers.ZeroAddress,
    seedData.target
  );
  const createReceipt = await createTx.wait();
  const createGas = createReceipt?.gasUsed ?? 0n;
  const marketId = beforeMarketId + 1n;

  let remaining = NUM_BINS;
  let cursor = 0;
  let totalSeedGas = 0n;
  let chunkIndex = 0;

  while (remaining > 0) {
    const count = remaining > CHUNK_SIZE ? CHUNK_SIZE : remaining;
    const seedTx = await core.seedNextChunks(marketId, count);
    const seedReceipt = await seedTx.wait();
    const gasUsed = seedReceipt?.gasUsed ?? 0n;
    totalSeedGas += gasUsed;
    console.log(
      `[seed] chunk=${chunkIndex} start=${cursor} count=${count} gas=${gasUsed.toString()}`
    );
    remaining -= count;
    cursor += count;
    chunkIndex += 1;
  }

  const totalGas = seedDeployGas + createGas + totalSeedGas;
  const gasPerBin = totalSeedGas / BigInt(NUM_BINS);

  console.log("--- gas summary ---");
  formatGas("SeedData deploy", seedDeployGas);
  formatGas("createMarket", createGas);
  formatGas("seedNextChunks total", totalSeedGas);
  formatGas("seedNextChunks avg/bin", gasPerBin);
  formatGas("TOTAL (deploy + create + seed)", totalGas);
  console.log("--- cost estimate ---");
  formatCost("SeedData deploy", seedDeployGas);
  formatCost("createMarket", createGas);
  formatCost("seedNextChunks total", totalSeedGas);
  formatCost("TOTAL", totalGas);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
