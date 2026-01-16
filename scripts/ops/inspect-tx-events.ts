import hre from "hardhat";

const TX_HASH = "0x4ec7a51232eae4963a351afe37795db253b6cb78fb6007ab061246eabd9d5683";

async function main() {
  const receipt = await hre.ethers.provider.getTransactionReceipt(TX_HASH);
  if (!receipt) {
    throw new Error("receipt not found");
  }

  const artifact = await hre.artifacts.readArtifact("MarketLifecycleModule");
  const iface = new hre.ethers.Interface(artifact.abi);

  const decoded: Array<Record<string, string>> = [];

  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog({ topics: log.topics, data: log.data });
      if (parsed.name === "MarketPnlRecorded") {
        decoded.push({
          name: parsed.name,
          marketId: parsed.args[0].toString(),
          batchId: parsed.args[1].toString(),
          lt: parsed.args[2].toString(),
          ftot: parsed.args[3].toString(),
        });
      } else if (parsed.name === "MarketSettledSecondary") {
        decoded.push({
          name: parsed.name,
          marketId: parsed.args[0].toString(),
          settlementValue: parsed.args[1].toString(),
          settlementTick: parsed.args[2].toString(),
          settlementFinalizedAt: parsed.args[3].toString(),
        });
      }
    } catch {
      // ignore logs not in lifecycle ABI
    }
  }

  console.log(JSON.stringify({ tx: TX_HASH, decoded }, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
