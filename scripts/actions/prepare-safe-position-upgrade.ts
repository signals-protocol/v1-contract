import fs from "fs";
import path from "path";
import hre from "hardhat";
import { loadEnvironment } from "../utils/environment";
import type { Environment } from "../types/environment";

const EXPECTED_CHAIN_IDS: Record<string, number> = {
  dev: 5115,
  prod: 4114,
};

function getTimestampTag(now: Date): string {
  const yyyy = now.getUTCFullYear().toString();
  const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(now.getUTCDate()).padStart(2, "0");
  const hh = String(now.getUTCHours()).padStart(2, "0");
  const mi = String(now.getUTCMinutes()).padStart(2, "0");
  const ss = String(now.getUTCSeconds()).padStart(2, "0");
  return `${yyyy}${mm}${dd}-${hh}${mi}${ss}Z`;
}

function printCopyBlock(label: string, value: string): void {
  console.log("");
  console.log(`----- COPY ${label} -----`);
  console.log(value);
  console.log(`----- END ${label} -----`);
}

function writeCopyFile(dir: string, fileName: string, value: string): void {
  fs.writeFileSync(path.join(dir, fileName), `${value}\n`);
}

async function main() {
  const { ethers, network } = hre;
  const env = network.name as Environment;

  const expectedChainId = EXPECTED_CHAIN_IDS[env];
  if (!expectedChainId) {
    throw new Error(
      `Unsupported environment "${env}". Expected: ${Object.keys(EXPECTED_CHAIN_IDS).join(", ")}`
    );
  }

  const [deployer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  if (Number(chainId) !== expectedChainId) {
    throw new Error(`ChainId mismatch: expected ${expectedChainId}, got ${chainId}`);
  }

  const envData = loadEnvironment(env);
  const positionProxy = envData.contracts.SignalsPositionProxy;
  if (!positionProxy) {
    throw new Error("Missing SignalsPositionProxy in environment file");
  }

  console.log(`[prepare-safe-position-upgrade] env=${env} chainId=${chainId.toString()}`);
  console.log(`[prepare-safe-position-upgrade] deployer=${deployer.address}`);
  console.log(`[prepare-safe-position-upgrade] positionProxy=${positionProxy}`);

  const positionImpl = await (
    await ethers.getContractFactory("SignalsPosition")
  ).deploy();
  await positionImpl.waitForDeployment();
  const newImpl = positionImpl.target.toString();
  console.log(`[prepare-safe-position-upgrade] new implementation deployed: ${newImpl}`);

  const positionIface = (await ethers.getContractFactory("SignalsPosition")).interface;
  const upgradeCalldata = positionIface.encodeFunctionData("upgradeToAndCall", [
    newImpl,
    "0x",
  ]);

  const safeAbi = [
    {
      type: "function",
      name: "upgradeToAndCall",
      stateMutability: "payable",
      inputs: [
        { name: "newImplementation", type: "address" },
        { name: "data", type: "bytes" },
      ],
      outputs: [],
    },
  ] as const;

  const plan = {
    generatedAt: new Date().toISOString(),
    network: env,
    chainId: Number(chainId),
    deployer: deployer.address,
    positionProxy,
    deployed: {
      SignalsPositionImplementation: newImpl,
    },
    safe: {
      to: positionProxy,
      value: "0",
      abi: safeAbi,
      method: "upgradeToAndCall(address newImplementation, bytes data)",
      args: {
        newImplementation: newImpl,
        data: "0x",
      },
      calldata: upgradeCalldata,
    },
  };

  const tag = getTimestampTag(new Date());
  const outPath = path.join("releases", env, `${tag}-safe-position-upgrade-plan.json`);
  const copyDir = path.join("releases", env, `${tag}-safe-position-upgrade-copy`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.mkdirSync(copyDir, { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(plan, null, 2));
  writeCopyFile(copyDir, "01-to.txt", positionProxy);
  writeCopyFile(copyDir, "02-value.txt", "0");
  writeCopyFile(copyDir, "03-position-abi.json", JSON.stringify(safeAbi));
  writeCopyFile(
    copyDir,
    "04-method.txt",
    "upgradeToAndCall(address newImplementation, bytes data)"
  );
  writeCopyFile(copyDir, "05-arg-newImplementation.txt", newImpl);
  writeCopyFile(copyDir, "06-arg-data.txt", "0x");
  writeCopyFile(copyDir, "07-calldata-upgradeToAndCall.txt", upgradeCalldata);

  console.log("");
  console.log("==============================================");
  console.log(`Safe Manual Execution (Citrea ${env}) [OWNER ONLY]`);
  console.log("==============================================");
  console.log("1) Safe -> New Transaction -> Contract Interaction");
  console.log("2) To = Position proxy, Value = 0");
  console.log("3) Paste ABI, choose upgradeToAndCall");
  console.log("4) Fill args or paste calldata in Data field");
  printCopyBlock("1_TO_POSITION", positionProxy);
  printCopyBlock("2_VALUE", "0");
  printCopyBlock("3_POSITION_ABI", JSON.stringify(safeAbi));
  printCopyBlock(
    "4_METHOD",
    "upgradeToAndCall(address newImplementation, bytes data)"
  );
  printCopyBlock("5_ARG_NEW_IMPLEMENTATION", newImpl);
  printCopyBlock("6_ARG_DATA", "0x");
  printCopyBlock("7_CALLDATA_DIRECT_PASTE", upgradeCalldata);
  console.log("");
  console.log(`[prepare-safe-position-upgrade] plan saved: ${outPath}`);
  console.log(`[prepare-safe-position-upgrade] copy files: ${copyDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
