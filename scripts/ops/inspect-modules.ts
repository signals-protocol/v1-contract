import hre from "hardhat";
import fs from "fs";
import path from "path";

const envPath = path.resolve(__dirname, "../environments/citrea-prod.json");
const env = JSON.parse(fs.readFileSync(envPath, "utf8"));

async function main() {
  const core = await hre.ethers.getContractAt("SignalsCore", env.contracts.SignalsCoreProxy);
  const out = {
    network: hre.network.name,
    core: await core.getAddress(),
    tradeModule: await core.tradeModule(),
    lifecycleModule: await core.lifecycleModule(),
    riskModule: await core.riskModule(),
    vaultModule: await core.vaultModule(),
    oracleModule: await core.oracleModule(),
  };
  console.log(JSON.stringify(out, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
