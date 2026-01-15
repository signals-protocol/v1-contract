import hre from "hardhat";
import { loadEnvironment, recordDeployment, updateContracts } from "../utils/environment";
import { buildReleaseMetaFromEnv, writeReleaseSnapshot } from "../utils/release";
import type { Environment } from "../types/environment";

export async function deployFeePoliciesAction(env: Environment) {
  const { ethers, network } = hre;
  console.log(`[deploy-fee-policies] environment=${env} network=${network.name}`);
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  const envData = loadEnvironment(env);

  const thetaBaseBpsRaw = process.env.THETA_BASE_BPS ?? "30";
  const thetaMaxBpsRaw = process.env.THETA_MAX_BPS ?? "3000";
  const thetaWindowSecRaw = process.env.THETA_WINDOW_SEC ?? "7200";
  const thetaBetaRaw = process.env.THETA_BETA ?? "4";
  const thetaBeta = Number(thetaBetaRaw);
  let thetaBaseBps: bigint;
  let thetaMaxBps: bigint;
  let thetaWindowSeconds: bigint;
  try {
    thetaBaseBps = BigInt(thetaBaseBpsRaw);
    thetaMaxBps = BigInt(thetaMaxBpsRaw);
    thetaWindowSeconds = BigInt(thetaWindowSecRaw);
  } catch {
    throw new Error(
      `Theta params must be integers (base=${thetaBaseBpsRaw} max=${thetaMaxBpsRaw} window=${thetaWindowSecRaw})`
    );
  }

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

  let thetaFeePolicyAddress: string | null = null;
  const coreAddress = envData.contracts.SignalsCoreProxy;
  if (coreAddress) {
    if (!Number.isFinite(thetaBeta)) {
      throw new Error(`THETA_BETA must be a number (got ${thetaBetaRaw})`);
    }
    const thetaFeePolicy = await (
      await ethers.getContractFactory("ThetaTimeFeePolicy")
    ).deploy(coreAddress, thetaBaseBps, thetaMaxBps, thetaWindowSeconds, thetaBeta);
    await thetaFeePolicy.waitForDeployment();
    thetaFeePolicyAddress = thetaFeePolicy.target.toString();
  } else {
    console.warn("[deploy-fee-policies] SignalsCoreProxy not set; skipping ThetaTimeFeePolicy");
  }

  updateContracts(env, {
    FeePolicyNull: nullFeePolicy.target.toString(),
    FeePolicy10bps: feePolicy10bps.target.toString(),
    FeePolicy50bps: feePolicy50bps.target.toString(),
    FeePolicy100bps: feePolicy100bps.target.toString(),
    FeePolicy200bps: feePolicy200bps.target.toString(),
    ...(thetaFeePolicyAddress ? { FeePolicyThetaTime: thetaFeePolicyAddress } : {}),
  });

  const releaseMeta = buildReleaseMetaFromEnv();
  const { data: envSnapshot, record } = recordDeployment(env, {
    action: "deploy-fee-policies",
    deployer: deployer.address,
    meta: releaseMeta,
  });
  writeReleaseSnapshot(env, envSnapshot, releaseMeta);

  console.log(`[deploy-fee-policies] completed (version=${record.version})`);
}
