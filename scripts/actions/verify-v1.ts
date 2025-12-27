import hre from "hardhat";
import { loadEnvironment } from "../utils/environment";
import type { Environment } from "../types/environment";

type VerifyTarget = {
  name: string;
  address?: string;
  contract: string;
  constructorArguments?: unknown[];
  libraries?: Record<string, string>;
};

function isStrict(env: Environment): boolean {
  return env === "citrea-prod" || process.env.STRICT_VERIFY === "1";
}

function parseNumber(value?: number | string): number | undefined {
  if (value === undefined || value === null) return undefined;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export async function verifyAction(env: Environment) {
  const { network } = hre;
  const strict = isStrict(env);
  console.log(`[verify] environment=${env} network=${network.name} strict=${strict ? "1" : "0"}`);
  const envData = loadEnvironment(env);

  const missing: string[] = [];
  const failures: string[] = [];

  const lazyAddress = envData.contracts.LazyMulSegmentTree;
  const moduleLibraries = lazyAddress ? { LazyMulSegmentTree: lazyAddress } : undefined;
  const canVerifyLinkedModules = Boolean(moduleLibraries);

  const defaultFeeBps = parseNumber(envData.config?.defaultFeeBps ?? process.env.DEFAULT_FEE_BPS);
  if (envData.contracts.FeePolicy && defaultFeeBps === undefined) {
    missing.push("MockFeePolicy constructor args (defaultFeeBps)");
  }
  if (!lazyAddress && (envData.contracts.TradeModule || envData.contracts.MarketLifecycleModule)) {
    missing.push("LazyMulSegmentTree library address");
  }

  const paymentTokenAddress = envData.contracts.SignalsUSDToken ?? envData.contracts.PaymentToken;
  const lpShareName = envData.config?.lpShareTokenName ?? process.env.LP_SHARE_NAME ?? "Signals LP";
  const lpShareSymbol = envData.config?.lpShareTokenSymbol ?? process.env.LP_SHARE_SYMBOL ?? "SIGLP";
  const canVerifyLpShare = Boolean(
    envData.contracts.SignalsLPShare && envData.contracts.SignalsCoreProxy && paymentTokenAddress
  );
  if (!paymentTokenAddress && (envData.contracts.SignalsCoreImplementation || envData.contracts.SignalsCoreProxy)) {
    missing.push("SignalsUSDToken (payment token) address");
  }

  if (envData.contracts.SignalsLPShare && !canVerifyLpShare) {
    if (!envData.contracts.SignalsCoreProxy) missing.push("SignalsCoreProxy address for LP share");
    if (!paymentTokenAddress) missing.push("SignalsUSDToken (payment token) address for LP share");
  }

  const targets: VerifyTarget[] = [
    {
      name: "SignalsCoreImplementation",
      address: envData.contracts.SignalsCoreImplementation,
      contract: "contracts/core/SignalsCore.sol:SignalsCore",
    },
    {
      name: "SignalsPositionImplementation",
      address: envData.contracts.SignalsPositionImplementation,
      contract: "contracts/position/SignalsPosition.sol:SignalsPosition",
    },
    {
      name: "LazyMulSegmentTree",
      address: envData.contracts.LazyMulSegmentTree,
      contract: "contracts/lib/LazyMulSegmentTree.sol:LazyMulSegmentTree",
    },
    ...(canVerifyLinkedModules
      ? [
          {
            name: "TradeModule",
            address: envData.contracts.TradeModule,
            contract: "contracts/modules/TradeModule.sol:TradeModule",
            libraries: moduleLibraries,
          },
          {
            name: "MarketLifecycleModule",
            address: envData.contracts.MarketLifecycleModule,
            contract: "contracts/modules/MarketLifecycleModule.sol:MarketLifecycleModule",
            libraries: moduleLibraries,
          },
        ]
      : []),
    {
      name: "OracleModule",
      address: envData.contracts.OracleModule,
      contract: "contracts/modules/OracleModule.sol:OracleModule",
    },
    ...(envData.contracts.RiskModule
      ? [
          {
            name: "RiskModule",
            address: envData.contracts.RiskModule,
            contract: "contracts/modules/RiskModule.sol:RiskModule",
          },
        ]
      : []),
    ...(envData.contracts.LPVaultModule || envData.contracts.VaultModule
      ? [
          {
            name: "LPVaultModule",
            address: envData.contracts.LPVaultModule ?? envData.contracts.VaultModule,
            contract: "contracts/modules/LPVaultModule.sol:LPVaultModule",
          },
        ]
      : []),
    {
      name: "MockFeePolicy",
      address: envData.contracts.FeePolicy,
      contract: "contracts/testonly/MockFeePolicy.sol:MockFeePolicy",
      constructorArguments: defaultFeeBps === undefined ? undefined : [defaultFeeBps],
    },
    ...(envData.contracts.FeePolicyNull
      ? [
          {
            name: "NullFeePolicy",
            address: envData.contracts.FeePolicyNull,
            contract: "contracts/fees/NullFeePolicy.sol:NullFeePolicy",
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy10bps
      ? [
          {
            name: "PercentFeePolicy10bps",
            address: envData.contracts.FeePolicy10bps,
            contract: "contracts/fees/PercentFeePolicies.sol:PercentFeePolicy10bps",
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy50bps
      ? [
          {
            name: "PercentFeePolicy50bps",
            address: envData.contracts.FeePolicy50bps,
            contract: "contracts/fees/PercentFeePolicies.sol:PercentFeePolicy50bps",
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy100bps
      ? [
          {
            name: "PercentFeePolicy100bps",
            address: envData.contracts.FeePolicy100bps,
            contract: "contracts/fees/PercentFeePolicies.sol:PercentFeePolicy100bps",
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy200bps
      ? [
          {
            name: "PercentFeePolicy200bps",
            address: envData.contracts.FeePolicy200bps,
            contract: "contracts/fees/PercentFeePolicies.sol:PercentFeePolicy200bps",
          },
        ]
      : []),
    {
      name: "SignalsUSDToken",
      address: paymentTokenAddress,
      contract: "contracts/tokens/SignalsUSDToken.sol:SignalsUSDToken",
    },
    ...(canVerifyLpShare
      ? [
          {
            name: "SignalsLPShare",
            address: envData.contracts.SignalsLPShare,
            contract: "contracts/tokens/SignalsLPShare.sol:SignalsLPShare",
            constructorArguments: [
              lpShareName,
              lpShareSymbol,
              envData.contracts.SignalsCoreProxy,
              paymentTokenAddress,
            ],
          },
        ]
      : []),
  ];

  for (const target of targets) {
    if (!target.address) {
      missing.push(`${target.name} address`);
      continue;
    }
    if (target.libraries && Object.values(target.libraries).some((value) => !value)) {
      missing.push(`${target.name} libraries`);
      continue;
    }

    try {
      console.log(`[verify] verifying ${target.name} (${target.address})`);
      const params: Record<string, unknown> = {
        address: target.address,
        contract: target.contract,
      };
      if (target.constructorArguments) {
        params.constructorArguments = target.constructorArguments;
      }
      if (target.libraries) {
        params.libraries = target.libraries;
      }
      await hre.run("verify:verify", params);
    } catch (err) {
      const message = (err as Error).message;
      const failure = `${target.name} (${target.address}): ${message}`;
      if (strict) {
        failures.push(failure);
      } else {
        console.warn(`[verify] skipping ${target.address}: ${message}`);
      }
    }
  }

  if (missing.length) {
    const msg = `[verify] missing inputs: ${missing.join(", ")}`;
    if (strict) {
      throw new Error(msg);
    }
    console.warn(msg);
  }

  if (failures.length) {
    throw new Error(`[verify] failed: ${failures.join(" | ")}`);
  }

  console.log("[verify] done");
}
