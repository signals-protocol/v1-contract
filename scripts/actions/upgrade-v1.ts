import hre from "hardhat";
import { appendHistory, loadEnvironment, updateContracts } from "../utils/environment";
import type { Environment } from "../types/environment";

export async function upgradeAction(env: Environment) {
  const { ethers, upgrades, network } = hre;
  console.log(`[upgrade] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  const envData = loadEnvironment(env);

  const coreProxyAddr = envData.contracts.SignalsCoreProxy;
  const positionProxyAddr = envData.contracts.SignalsPositionProxy;
  if (!coreProxyAddr || !positionProxyAddr) {
    throw new Error("Missing proxy addresses in environment file");
  }

  const coreFactory = await ethers.getContractFactory("SignalsCore");
  const upgradedCore = await upgrades.upgradeProxy(coreProxyAddr, coreFactory, { kind: "uups" });
  await upgradedCore.waitForDeployment();
  const newCoreImpl = await upgrades.erc1967.getImplementationAddress(upgradedCore.target);

  const positionFactory = await ethers.getContractFactory("SignalsPosition");
  const upgradedPosition = await upgrades.upgradeProxy(positionProxyAddr, positionFactory, { kind: "uups" });
  await upgradedPosition.waitForDeployment();
  const newPositionImpl = await upgrades.erc1967.getImplementationAddress(upgradedPosition.target);

  updateContracts(env, {
    SignalsCoreImplementation: newCoreImpl,
    SignalsPositionImplementation: newPositionImpl,
  });

  appendHistory(env, {
    version: envData.version + 1,
    action: "upgrade",
    deployer: deployer.address,
    timestamp: Math.floor(Date.now() / 1000),
  });

  console.log("[upgrade] completed");
}
