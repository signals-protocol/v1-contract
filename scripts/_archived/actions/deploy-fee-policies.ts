import hre from 'hardhat';
import {
  loadEnvironment,
  recordDeployment,
  updateContracts,
} from '../utils/environment';
import { writeReleaseSnapshot } from '../utils/release';
import type { Environment } from '../types/environment';

export async function deployFeePoliciesAction(env: Environment) {
  const { ethers, network } = hre;
  console.log(
    `[deploy-fee-policies] environment=${env} network=${network.name}`,
  );
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  loadEnvironment(env);

  const nullFeePolicy = await (
    await ethers.getContractFactory('NullFeePolicy')
  ).deploy();
  await nullFeePolicy.waitForDeployment();

  const feePolicy10bps = await (
    await ethers.getContractFactory('PercentFeePolicy10bps')
  ).deploy();
  await feePolicy10bps.waitForDeployment();

  const feePolicy50bps = await (
    await ethers.getContractFactory('PercentFeePolicy50bps')
  ).deploy();
  await feePolicy50bps.waitForDeployment();

  const feePolicy100bps = await (
    await ethers.getContractFactory('PercentFeePolicy100bps')
  ).deploy();
  await feePolicy100bps.waitForDeployment();

  const feePolicy200bps = await (
    await ethers.getContractFactory('PercentFeePolicy200bps')
  ).deploy();
  await feePolicy200bps.waitForDeployment();

  updateContracts(env, {
    FeePolicyNull: nullFeePolicy.target.toString(),
    FeePolicy10bps: feePolicy10bps.target.toString(),
    FeePolicy50bps: feePolicy50bps.target.toString(),
    FeePolicy100bps: feePolicy100bps.target.toString(),
    FeePolicy200bps: feePolicy200bps.target.toString(),
  });

  const { data: envSnapshot, record } = recordDeployment(env, {
    action: 'deploy-fee-policies',
    deployer: deployer.address,
  });
  writeReleaseSnapshot(env, envSnapshot);

  console.log(`[deploy-fee-policies] completed (version=${record.version})`);
}
