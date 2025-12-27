import hre from "hardhat";
import { recordDeployment, updateContracts } from "../utils/environment";
import { buildReleaseMetaFromEnv, writeReleaseSnapshot } from "../utils/release";
import type { Environment } from "../types/environment";

export async function deployFeePoliciesAction(env: Environment) {
  const { ethers, network } = hre;
  console.log(`[deploy-fee-policies] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const nullFeePolicy = await (await ethers.getContractFactory("NullFeePolicy")).deploy();
  await nullFeePolicy.waitForDeployment();

  const feePolicy10bps = await (await ethers.getContractFactory("PercentFeePolicy10bps")).deploy();
  await feePolicy10bps.waitForDeployment();

  const feePolicy50bps = await (await ethers.getContractFactory("PercentFeePolicy50bps")).deploy();
  await feePolicy50bps.waitForDeployment();

  const feePolicy100bps = await (await ethers.getContractFactory("PercentFeePolicy100bps")).deploy();
  await feePolicy100bps.waitForDeployment();

  const feePolicy200bps = await (await ethers.getContractFactory("PercentFeePolicy200bps")).deploy();
  await feePolicy200bps.waitForDeployment();

  updateContracts(env, {
    FeePolicyNull: nullFeePolicy.target.toString(),
    FeePolicy10bps: feePolicy10bps.target.toString(),
    FeePolicy50bps: feePolicy50bps.target.toString(),
    FeePolicy100bps: feePolicy100bps.target.toString(),
    FeePolicy200bps: feePolicy200bps.target.toString(),
  });

  const releaseMeta = buildReleaseMetaFromEnv();
  const { data: envData, record } = recordDeployment(env, {
    action: "deploy-fee-policies",
    deployer: deployer.address,
    meta: releaseMeta,
  });
  writeReleaseSnapshot(env, envData, releaseMeta);

  console.log(`[deploy-fee-policies] completed (version=${record.version})`);
}
