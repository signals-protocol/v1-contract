import hre from "hardhat";
import { loadEnvironment } from "../utils/environment";
import type { Environment } from "../types/environment";

export async function safetyCheckAction(env: Environment) {
  const { ethers, upgrades, network } = hre;
  console.log(`[safety-check] environment=${env} network=${network.name}`);
  const envData = loadEnvironment(env);

  const required = [
    "SignalsCoreProxy",
    "SignalsCoreImplementation",
    "SignalsPositionProxy",
    "SignalsPositionImplementation",
  ];
  for (const key of required) {
    if (!envData.contracts[key]) {
      throw new Error(`Missing ${key} in environment file`);
    }
  }

  const coreProxy = envData.contracts.SignalsCoreProxy;
  const positionProxy = envData.contracts.SignalsPositionProxy;

  const coreImpl = await upgrades.erc1967.getImplementationAddress(coreProxy);
  const positionImpl = await upgrades.erc1967.getImplementationAddress(positionProxy);

  if (coreImpl.toLowerCase() !== envData.contracts.SignalsCoreImplementation.toLowerCase()) {
    throw new Error(`Core impl mismatch: manifest=${coreImpl} env=${envData.contracts.SignalsCoreImplementation}`);
  }
  if (positionImpl.toLowerCase() !== envData.contracts.SignalsPositionImplementation.toLowerCase()) {
    throw new Error(
      `Position impl mismatch: manifest=${positionImpl} env=${envData.contracts.SignalsPositionImplementation}`
    );
  }

  const codeChecks = ["TradeModule", "MarketLifecycleModule", "OracleModule"];
  for (const name of codeChecks) {
    const addr = envData.contracts[name];
    if (!addr) throw new Error(`Missing ${name} address`);
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${name} has no code at ${addr}`);
  }

  console.log("[safety-check] OK");
}
