import hre from "hardhat";
import { loadEnvironment } from "../utils/environment";
import type { Environment } from "../types/environment";

export async function verifyAction(env: Environment) {
  const { ethers, network } = hre;
  console.log(`[verify] environment=${env} network=${network.name}`);
  const envData = loadEnvironment(env);

  const verifyList = [
    envData.contracts.SignalsCoreImplementation,
    envData.contracts.SignalsPositionImplementation,
    envData.contracts.TradeModule,
    envData.contracts.MarketLifecycleModule,
    envData.contracts.OracleModule,
    envData.contracts.FeePolicy,
    envData.contracts.PaymentToken,
  ].filter(Boolean) as string[];

  for (const addr of verifyList) {
    try {
      console.log(`[verify] verifying ${addr}`);
      await hre.run("verify:verify", { address: addr });
    } catch (err) {
      console.warn(`[verify] skipping ${addr}: ${(err as Error).message}`);
    }
  }
  console.log("[verify] done");
}
