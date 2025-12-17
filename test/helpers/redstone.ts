import { ethers } from "hardhat";
import {
  DataPackage,
  NumericDataPoint,
  RedstonePayload,
} from "@redstone-finance/protocol";
import type { Wallet } from "ethers";

// Redstone configuration constants
export const DATA_FEED_ID = "BTC";
export const DATA_SERVICE_ID = "redstone-primary-prod";
export const FEED_DECIMALS = 8;
export const UNIQUE_SIGNERS_THRESHOLD = 3;

// Hardhat default accounts for testing (authorized signers in PrimaryProdDataServiceConsumerBase)
export const AUTHORISED_SIGNER_KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // hardhat default #0
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // hardhat default #1
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // hardhat default #2
];

export const authorisedWallets = AUTHORISED_SIGNER_KEYS.map(
  (key) => new ethers.Wallet(key)
);

// Interface for encoding submitSettlementSample call
export const SUBMIT_IFACE = new ethers.Interface([
  "function submitSettlementSample(uint256 marketId)",
]);

/**
 * Build a signed data package for a single signer
 */
export function buildSignedDataPackage(
  valueWithDecimals: number,
  timestampSec: number,
  signer: Wallet
) {
  const dataPoint = new NumericDataPoint({
    dataFeedId: DATA_FEED_ID,
    value: valueWithDecimals,
    decimals: FEED_DECIMALS,
  });
  const pkg = new DataPackage(
    [dataPoint],
    timestampSec * 1000, // Redstone protocol uses ms
    DATA_FEED_ID
  );
  return pkg.sign(signer.privateKey);
}

/**
 * Build Redstone payload with multiple signers
 */
export function buildRedstonePayload(
  valueWithDecimals: number,
  timestampSec: number,
  signers: Wallet[] = authorisedWallets
) {
  const signedPackages = signers.map((signer) =>
    buildSignedDataPackage(valueWithDecimals, timestampSec, signer)
  );
  return RedstonePayload.prepare(signedPackages, DATA_SERVICE_ID);
}

/**
 * Submit settlement sample with Redstone payload appended to calldata
 */
export async function submitWithPayload(
  core: { getAddress: () => Promise<string> },
  submitter: {
    sendTransaction: (tx: { to: string; data: string }) => Promise<any>;
  },
  marketId: number | bigint,
  payload?: string
) {
  const baseData = SUBMIT_IFACE.encodeFunctionData("submitSettlementSample", [
    marketId,
  ]);
  const data =
    payload === undefined
      ? baseData
      : `${baseData}${payload.replace(/^0x/, "")}`;
  return submitter.sendTransaction({
    to: await core.getAddress(),
    data,
  });
}

/**
 * Helper: Convert human-readable price to expected settlement value
 *
 * NumericDataPoint encoding: value * 10^decimals
 * On-chain extraction returns: value * 10^8 (for decimals=8)
 * OracleModule scales down: price / 10^(8-6) = price / 100
 *
 * So for human price P:
 *   Encoded = P * 10^8
 *   Extracted = P * 10^8
 *   SettlementValue = P * 10^8 / 100 = P * 10^6
 *
 * Example: humanPrice=2 => settlementValue=2000000
 */
export function toSettlementValue(humanPrice: number): bigint {
  return BigInt(humanPrice * 1_000_000);
}

/**
 * Helper: Convert settlement value to settlement tick
 * Tick = settlementValue / 1_000_000
 */
export function toSettlementTick(settlementValue: bigint): bigint {
  return settlementValue / 1_000_000n;
}
