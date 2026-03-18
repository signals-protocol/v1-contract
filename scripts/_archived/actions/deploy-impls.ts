import hre from 'hardhat';
import {
  loadEnvironment,
  recordDeployment,
  updateContracts,
} from '../utils/environment';
import { writeReleaseSnapshot } from '../utils/release';
import type { Environment } from '../types/environment';

export async function deployImplsAction(env: Environment) {
  const { ethers, network } = hre;
  console.log(`[deploy-impls] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const envData = loadEnvironment(env);

  let create2FactoryAddress =
    envData.contracts.SignalsCreate2Factory ?? envData.contracts.Create2Factory;
  if (!create2FactoryAddress) {
    const factory = await (
      await ethers.getContractFactory('SignalsCreate2Factory')
    ).deploy(deployer.address);
    await factory.waitForDeployment();
    create2FactoryAddress = factory.target.toString();
  }

  const factoryCode = await ethers.provider.getCode(create2FactoryAddress);
  if (factoryCode === '0x') {
    throw new Error(
      `SignalsCreate2Factory has no code at ${create2FactoryAddress}`,
    );
  }

  const coreImpl = await (
    await ethers.getContractFactory('SignalsCore')
  ).deploy();
  await coreImpl.waitForDeployment();

  const positionImpl = await (
    await ethers.getContractFactory('SignalsPosition')
  ).deploy();
  await positionImpl.waitForDeployment();

  const lpShareImpl = await (
    await ethers.getContractFactory('SignalsLPShare')
  ).deploy();
  await lpShareImpl.waitForDeployment();

  updateContracts(env, {
    SignalsCreate2Factory: create2FactoryAddress,
    SignalsCoreImplementation: coreImpl.target.toString(),
    SignalsPositionImplementation: positionImpl.target.toString(),
    SignalsLPShareImplementation: lpShareImpl.target.toString(),
  });

  const { data: envSnapshot, record } = recordDeployment(env, {
    action: 'deploy-impls',
    deployer: deployer.address,
  });
  writeReleaseSnapshot(env, envSnapshot);

  console.log(`[deploy-impls] completed (version=${record.version})`);
}
