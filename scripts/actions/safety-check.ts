import hre from "hardhat";
import { loadEnvironment } from "../utils/environment";
import type { Environment } from "../types/environment";

function assertAddressMatch(label: string, actual: string, expected?: string) {
  if (!expected) return;
  if (actual.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`${label} mismatch: chain=${actual} env=${expected}`);
  }
}

function toBigIntString(value: bigint): string {
  return value.toString();
}

export async function safetyCheckAction(env: Environment) {
  const { ethers, upgrades, network } = hre;
  console.log(`[safety-check] environment=${env} network=${network.name}`);
  const envData = loadEnvironment(env);

  const required = [
    "SignalsCoreProxy",
    "SignalsCoreImplementation",
    "SignalsPositionProxy",
    "SignalsPositionImplementation",
    "TradeModule",
    "MarketLifecycleModule",
    "RiskModule",
    "LPVaultModule",
    "OracleModule",
    "FeePolicy",
    "SignalsLPShare",
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

  const core = await ethers.getContractAt("SignalsCore", coreProxy);
  const position = await ethers.getContractAt("SignalsPosition", positionProxy);

  const expectedCoreOwner = envData.config?.owners?.core;
  const expectedPositionOwner = envData.config?.owners?.position;
  if (expectedCoreOwner) {
    const actual = await core.owner();
    assertAddressMatch("Core owner", actual, expectedCoreOwner);
  } else {
    console.warn("[safety-check] expected core owner not set in environment config");
  }
  if (expectedPositionOwner) {
    const actual = await position.owner();
    assertAddressMatch("Position owner", actual, expectedPositionOwner);
  } else {
    console.warn("[safety-check] expected position owner not set in environment config");
  }

  const moduleChecks = [
    {
      name: "TradeModule",
      actual: await core.tradeModule(),
      expected: envData.contracts.TradeModule,
    },
    {
      name: "MarketLifecycleModule",
      actual: await core.lifecycleModule(),
      expected: envData.contracts.MarketLifecycleModule,
    },
    {
      name: "OracleModule",
      actual: await core.oracleModule(),
      expected: envData.contracts.OracleModule,
    },
    {
      name: "RiskModule",
      actual: await core.riskModule(),
      expected: envData.contracts.RiskModule,
    },
    {
      name: "LPVaultModule",
      actual: await core.vaultModule(),
      expected: envData.contracts.LPVaultModule ?? envData.contracts.VaultModule,
    },
  ];
  for (const module of moduleChecks) {
    if (!module.expected) {
      if (["TradeModule", "MarketLifecycleModule", "OracleModule"].includes(module.name)) {
        throw new Error(`Missing ${module.name} in environment file`);
      }
      continue;
    }
    assertAddressMatch(`${module.name} address`, module.actual, module.expected);
  }

  const positionCore = await position.core();
  assertAddressMatch("Position core", positionCore, coreProxy);

  const corePosition = await core.positionContract();
  assertAddressMatch("Core positionContract", corePosition, positionProxy);

  const paymentToken = await core.paymentToken();
  const expectedPaymentToken = envData.contracts.SignalsUSDToken ?? envData.contracts.PaymentToken;
  if (!expectedPaymentToken) {
    throw new Error("Missing SignalsUSDToken (payment token) in environment file");
  }
  assertAddressMatch("Payment token", paymentToken, expectedPaymentToken);

  const lpShareToken = await core.lpShareToken();
  assertAddressMatch("LP share token", lpShareToken, envData.contracts.SignalsLPShare);

  const submitWindow = envData.config?.settlementSubmitWindow;
  if (submitWindow) {
    const actual = await core.settlementSubmitWindow();
    if (toBigIntString(actual) !== submitWindow) {
      throw new Error(`settlementSubmitWindow mismatch: chain=${actual} env=${submitWindow}`);
    }
  }

  const finalizeDeadline = envData.config?.settlementFinalizeDeadline;
  if (finalizeDeadline) {
    const actual = await core.claimDelaySeconds();
    if (toBigIntString(actual) !== finalizeDeadline) {
      throw new Error(`claimDelaySeconds mismatch: chain=${actual} env=${finalizeDeadline}`);
    }
  }

  const pendingOpsWindow = envData.config?.pendingOpsWindow;
  if (pendingOpsWindow) {
    const actual = await core.pendingOpsWindow();
    if (toBigIntString(actual) !== pendingOpsWindow) {
      throw new Error(`pendingOpsWindow mismatch: chain=${actual} env=${pendingOpsWindow}`);
    }
  }
  if (submitWindow && pendingOpsWindow && finalizeDeadline) {
    const expectedClaim = BigInt(submitWindow) + BigInt(pendingOpsWindow);
    if (BigInt(finalizeDeadline) !== expectedClaim) {
      throw new Error(
        `claimDelaySeconds invariant mismatch: submit=${submitWindow} ops=${pendingOpsWindow} claim=${finalizeDeadline}`
      );
    }
  }

  const redstoneFeedId = envData.config?.redstoneFeedId;
  if (redstoneFeedId) {
    const expected = ethers.encodeBytes32String(redstoneFeedId);
    const actual = await core.redstoneFeedId();
    if (actual.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`redstoneFeedId mismatch: chain=${actual} env=${expected}`);
    }
  }

  const redstoneFeedDecimals = envData.config?.redstoneFeedDecimals;
  if (redstoneFeedDecimals !== undefined) {
    const actual = await core.redstoneFeedDecimals();
    if (Number(actual) !== redstoneFeedDecimals) {
      throw new Error(`redstoneFeedDecimals mismatch: chain=${actual} env=${redstoneFeedDecimals}`);
    }
  }

  const redstoneMaxSampleDistance = envData.config?.redstoneMaxSampleDistance;
  if (redstoneMaxSampleDistance) {
    const actual = await core.maxSampleDistance();
    if (toBigIntString(actual) !== redstoneMaxSampleDistance) {
      throw new Error(`maxSampleDistance mismatch: chain=${actual} env=${redstoneMaxSampleDistance}`);
    }
  }

  const redstoneFutureTolerance = envData.config?.redstoneFutureTolerance;
  if (redstoneFutureTolerance) {
    const actual = await core.futureTolerance();
    if (toBigIntString(actual) !== redstoneFutureTolerance) {
      throw new Error(`futureTolerance mismatch: chain=${actual} env=${redstoneFutureTolerance}`);
    }
  }

  const codeChecks = [
    "TradeModule",
    "MarketLifecycleModule",
    "RiskModule",
    "LPVaultModule",
    "OracleModule",
    "FeePolicy",
    "FeePolicyNull",
    "FeePolicy10bps",
    "FeePolicy50bps",
    "FeePolicy100bps",
    "FeePolicy200bps",
    "SignalsUSDToken",
    "SignalsLPShare",
    "LazyMulSegmentTree",
  ];
  if (!envData.contracts.SignalsUSDToken && envData.contracts.PaymentToken) {
    codeChecks.push("PaymentToken");
  }
  for (const name of codeChecks) {
    const addr = envData.contracts[name];
    if (!addr) continue;
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${name} has no code at ${addr}`);
  }

  console.log("[safety-check] OK");
}
