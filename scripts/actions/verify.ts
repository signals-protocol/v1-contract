import { execFileSync } from 'child_process';
import { loadEnvironment, normalizeEnvironment } from '../utils/environment';
import type { Environment } from '../types/environment';

type VerifyTarget = {
  name: string;
  address?: string;
  contract: string;
  constructorArgs?: string[];
  libraries?: Record<string, string>;
};

const COMPILER_VERSION = '0.8.28';

function isStrict(env: Environment): boolean {
  return env === 'prod' || process.env.STRICT_VERIFY === '1';
}

function forgeVerify(target: VerifyTarget, env: Environment): void {
  const args: string[] = [
    'verify-contract',
    '--chain',
    env === 'dev' ? '5115' : '4114',
    '--watch',
    '--compiler-version',
    COMPILER_VERSION,
  ];

  if (target.constructorArgs && target.constructorArgs.length > 0) {
    const types = target.constructorArgs.map((a) =>
      a.startsWith('0x') && a.length === 42 ? 'address' : 'bytes',
    );
    const encoded = execFileSync('cast', [
      'abi-encode',
      `constructor(${types.join(',')})`,
      ...target.constructorArgs,
    ])
      .toString()
      .trim();
    args.push('--constructor-args', encoded);
  }

  if (target.libraries) {
    for (const [name, addr] of Object.entries(target.libraries)) {
      args.push('--libraries', `contracts/lib/${name}.sol:${name}:${addr}`);
    }
  }

  args.push(target.address!, target.contract);

  // Use etherscan config from foundry.toml via --etherscan-api-key and --verifier-url
  // so foundry.toml [etherscan] section is used automatically via --chain
  execFileSync('forge', args, {
    stdio: 'inherit',
    env: { ...process.env },
  });
}

function main() {
  const rawEnv = process.env.ENV;
  if (!rawEnv) {
    console.error('Usage: ENV=dev|prod tsx scripts/actions/verify.ts');
    process.exit(1);
  }
  const env = normalizeEnvironment(rawEnv);
  const strict = isStrict(env);
  console.log(`[verify] environment=${env} strict=${strict ? '1' : '0'}`);
  const envData = loadEnvironment(env);

  const missing: string[] = [];
  const failures: string[] = [];

  const lazyAddress = envData.contracts.LazyMulSegmentTree;
  const moduleLibraries = lazyAddress
    ? { LazyMulSegmentTree: lazyAddress }
    : undefined;
  const canVerifyLinkedModules = Boolean(moduleLibraries);

  const paymentTokenAddress = envData.contracts.PaymentToken;
  const satsumaSwapRouter = envData.contracts.SatsumaSwapRouter;
  const routerOwner = envData.config?.owners?.core;
  const paymentTokenVerifyContract =
    envData.config?.paymentTokenVerifyContract ??
    process.env.PAYMENT_TOKEN_VERIFY_CONTRACT;
  if (
    !paymentTokenAddress &&
    (envData.contracts.SignalsCoreImplementation ||
      envData.contracts.SignalsCoreProxy)
  ) {
    missing.push('PaymentToken address');
  }
  if (
    envData.contracts.SignalsRouter &&
    (!envData.contracts.SignalsCoreProxy ||
      !envData.contracts.SignalsPositionProxy ||
      !paymentTokenAddress ||
      !satsumaSwapRouter ||
      !routerOwner)
  ) {
    if (!envData.contracts.SignalsCoreProxy)
      missing.push('SignalsCoreProxy (for SignalsRouter)');
    if (!envData.contracts.SignalsPositionProxy)
      missing.push('SignalsPositionProxy (for SignalsRouter)');
    if (!paymentTokenAddress) missing.push('PaymentToken (for SignalsRouter)');
    if (!satsumaSwapRouter)
      missing.push('SatsumaSwapRouter (for SignalsRouter)');
    if (!routerOwner) missing.push('config.owners.core (for SignalsRouter)');
  }
  const deployerEOA = envData.config?.deployerEOA ?? process.env.DEPLOYER_EOA;
  if (
    !deployerEOA &&
    (envData.contracts.SignalsCreate2Factory ||
      envData.contracts.SignalsDeployer)
  ) {
    missing.push('deployerEOA (for SignalsCreate2Factory / SignalsDeployer)');
  }
  const coreImpl = envData.contracts.SignalsCoreImplementation;
  const positionImpl = envData.contracts.SignalsPositionImplementation;
  const lpShareImpl = envData.contracts.SignalsLPShareImplementation;
  const proxyContract =
    '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy';
  if (envData.contracts.SignalsCoreProxy && !coreImpl) {
    missing.push('SignalsCoreImplementation (for SignalsCoreProxy)');
  }
  if (envData.contracts.SignalsPositionProxy && !positionImpl) {
    missing.push('SignalsPositionImplementation (for SignalsPositionProxy)');
  }
  if (envData.contracts.SignalsLPShareProxy && !lpShareImpl) {
    missing.push('SignalsLPShareImplementation (for SignalsLPShareProxy)');
  }

  const targets: VerifyTarget[] = [
    {
      name: 'SignalsCoreImplementation',
      address: coreImpl,
      contract: 'contracts/core/SignalsCore.sol:SignalsCore',
    },
    {
      name: 'SignalsPositionImplementation',
      address: positionImpl,
      contract: 'contracts/position/SignalsPosition.sol:SignalsPosition',
    },
    {
      name: 'SignalsLPShareImplementation',
      address: lpShareImpl,
      contract: 'contracts/tokens/SignalsLPShare.sol:SignalsLPShare',
    },
    ...(envData.contracts.SignalsCoreProxy
      ? [
          {
            name: 'SignalsCoreProxy',
            address: envData.contracts.SignalsCoreProxy,
            contract: proxyContract,
            constructorArgs: coreImpl ? [coreImpl, '0x'] : undefined,
          },
        ]
      : []),
    ...(envData.contracts.SignalsPositionProxy
      ? [
          {
            name: 'SignalsPositionProxy',
            address: envData.contracts.SignalsPositionProxy,
            contract: proxyContract,
            constructorArgs: positionImpl ? [positionImpl, '0x'] : undefined,
          },
        ]
      : []),
    ...(envData.contracts.SignalsLPShareProxy
      ? [
          {
            name: 'SignalsLPShareProxy',
            address: envData.contracts.SignalsLPShareProxy,
            contract: proxyContract,
            constructorArgs: lpShareImpl ? [lpShareImpl, '0x'] : undefined,
          },
        ]
      : []),
    {
      name: 'LazyMulSegmentTree',
      address: envData.contracts.LazyMulSegmentTree,
      contract: 'contracts/lib/LazyMulSegmentTree.sol:LazyMulSegmentTree',
    },
    ...(envData.contracts.SignalsCreate2Factory && deployerEOA
      ? [
          {
            name: 'SignalsCreate2Factory',
            address: envData.contracts.SignalsCreate2Factory,
            contract:
              'contracts/deploy/SignalsCreate2Factory.sol:SignalsCreate2Factory',
            constructorArgs: [deployerEOA],
          },
        ]
      : []),
    ...(envData.contracts.SignalsDeployer && deployerEOA
      ? [
          {
            name: 'SignalsDeployer',
            address: envData.contracts.SignalsDeployer,
            contract: 'contracts/deploy/SignalsDeployer.sol:SignalsDeployer',
            constructorArgs: [deployerEOA],
          },
        ]
      : []),
    ...(canVerifyLinkedModules
      ? [
          {
            name: 'TradeModule',
            address: envData.contracts.TradeModule,
            contract: 'contracts/modules/TradeModule.sol:TradeModule',
            libraries: moduleLibraries,
          },
          {
            name: 'MarketLifecycleModule',
            address: envData.contracts.MarketLifecycleModule,
            contract:
              'contracts/modules/MarketLifecycleModule.sol:MarketLifecycleModule',
            libraries: moduleLibraries,
          },
        ]
      : []),
    {
      name: 'OracleModule',
      address: envData.contracts.OracleModule,
      contract: 'contracts/modules/OracleModule.sol:OracleModule',
    },
    ...(envData.contracts.RiskModule
      ? [
          {
            name: 'RiskModule',
            address: envData.contracts.RiskModule,
            contract: 'contracts/modules/RiskModule.sol:RiskModule',
          },
        ]
      : []),
    ...(envData.contracts.LPVaultModule || envData.contracts.VaultModule
      ? [
          {
            name: 'LPVaultModule',
            address:
              envData.contracts.LPVaultModule ?? envData.contracts.VaultModule,
            contract: 'contracts/modules/LPVaultModule.sol:LPVaultModule',
          },
        ]
      : []),
    ...(envData.contracts.DecommissionModule
      ? [
          {
            name: 'DecommissionModule',
            address: envData.contracts.DecommissionModule,
            contract:
              'contracts/modules/DecommissionModule.sol:DecommissionModule',
            constructorArgs: paymentTokenAddress
              ? [paymentTokenAddress]
              : undefined,
          },
        ]
      : []),
    ...(envData.contracts.FeePolicyNull
      ? [
          {
            name: 'NullFeePolicy',
            address: envData.contracts.FeePolicyNull,
            contract: 'contracts/fees/NullFeePolicy.sol:NullFeePolicy',
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy10bps
      ? [
          {
            name: 'PercentFeePolicy10bps',
            address: envData.contracts.FeePolicy10bps,
            contract:
              'contracts/fees/PercentFeePolicies.sol:PercentFeePolicy10bps',
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy50bps
      ? [
          {
            name: 'PercentFeePolicy50bps',
            address: envData.contracts.FeePolicy50bps,
            contract:
              'contracts/fees/PercentFeePolicies.sol:PercentFeePolicy50bps',
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy100bps
      ? [
          {
            name: 'PercentFeePolicy100bps',
            address: envData.contracts.FeePolicy100bps,
            contract:
              'contracts/fees/PercentFeePolicies.sol:PercentFeePolicy100bps',
          },
        ]
      : []),
    ...(envData.contracts.FeePolicy200bps
      ? [
          {
            name: 'PercentFeePolicy200bps',
            address: envData.contracts.FeePolicy200bps,
            contract:
              'contracts/fees/PercentFeePolicies.sol:PercentFeePolicy200bps',
          },
        ]
      : []),
    ...(paymentTokenAddress && paymentTokenVerifyContract
      ? [
          {
            name: 'PaymentToken',
            address: paymentTokenAddress,
            contract: paymentTokenVerifyContract,
          },
        ]
      : []),
    ...(envData.contracts.SignalsRouter
      ? [
          {
            name: 'SignalsRouter',
            address: envData.contracts.SignalsRouter,
            contract: 'contracts/router/SignalsRouter.sol:SignalsRouter',
            constructorArgs:
              envData.contracts.SignalsCoreProxy &&
              envData.contracts.SignalsPositionProxy &&
              paymentTokenAddress &&
              satsumaSwapRouter &&
              routerOwner
                ? [
                    envData.contracts.SignalsCoreProxy,
                    envData.contracts.SignalsPositionProxy,
                    paymentTokenAddress,
                    satsumaSwapRouter,
                    '0x0000000000000000000000000000000000000000',
                    routerOwner,
                  ]
                : undefined,
          },
        ]
      : []),
  ];

  for (const target of targets) {
    if (!target.address) {
      missing.push(`${target.name} address`);
      continue;
    }
    if (
      target.libraries &&
      Object.values(target.libraries).some((value) => !value)
    ) {
      missing.push(`${target.name} libraries`);
      continue;
    }

    try {
      console.log(`[verify] verifying ${target.name} (${target.address})`);
      forgeVerify(target, env);
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
    const msg = `[verify] missing inputs: ${missing.join(', ')}`;
    if (strict) {
      throw new Error(msg);
    }
    console.warn(msg);
  }

  if (failures.length) {
    throw new Error(`[verify] failed: ${failures.join(' | ')}`);
  }

  console.log('[verify] done');
}

main();
