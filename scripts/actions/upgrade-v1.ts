import hre from "hardhat";
import { loadEnvironment, recordDeployment, updateContracts } from "../utils/environment";
import { buildReleaseMetaFromEnv, writeReleaseSnapshot } from "../utils/release";
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
  const upgradedCore = await upgrades.upgradeProxy(coreProxyAddr, coreFactory, {
    kind: "uups",
    unsafeAllow: ["delegatecall"],
  });
  await upgradedCore.waitForDeployment();
  const newCoreImpl = await upgrades.erc1967.getImplementationAddress(await upgradedCore.getAddress());

  const positionFactory = await ethers.getContractFactory("SignalsPosition");
  const upgradedPosition = await upgrades.upgradeProxy(positionProxyAddr, positionFactory, { kind: "uups" });
  await upgradedPosition.waitForDeployment();
  const newPositionImpl = await upgrades.erc1967.getImplementationAddress(await upgradedPosition.getAddress());

  updateContracts(env, {
    SignalsCoreImplementation: newCoreImpl,
    SignalsPositionImplementation: newPositionImpl,
  });

  const releaseMeta = buildReleaseMetaFromEnv();
  const { data: updatedEnv, record } = recordDeployment(env, {
    action: "upgrade",
    deployer: deployer.address,
    meta: releaseMeta,
  });
  writeReleaseSnapshot(env, updatedEnv, releaseMeta);

  console.log(`[upgrade] completed (version=${record.version})`);
}
