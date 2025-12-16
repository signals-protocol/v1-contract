import { ethers } from "hardhat";

// WAD (18 decimals) constants
export const WAD = ethers.parseEther("1");
export const HALF_WAD = ethers.parseEther("0.5");
export const TWO_WAD = ethers.parseEther("2");

// USDC (6 decimals) constants
export const USDC_DECIMALS = 6;
export const INITIAL_SUPPLY = ethers.parseUnits("1000000000000", USDC_DECIMALS);

// Market constants
export const ALPHA = ethers.parseEther("1");
export const TICK_COUNT = 100;
export const MARKET_DURATION = 7 * 24 * 60 * 60; // 7 days

// Test quantities (6 decimals)
export const SMALL_QUANTITY = ethers.parseUnits("0.001", USDC_DECIMALS);
export const MEDIUM_QUANTITY = ethers.parseUnits("0.01", USDC_DECIMALS);
export const LARGE_QUANTITY = ethers.parseUnits("0.1", USDC_DECIMALS);

// Cost limits (6 decimals)
export const SMALL_COST = ethers.parseUnits("0.01", USDC_DECIMALS);
export const MEDIUM_COST = ethers.parseUnits("0.1", USDC_DECIMALS);
export const LARGE_COST = ethers.parseUnits("1", USDC_DECIMALS);

// Factor limits (WAD)
export const MIN_FACTOR = ethers.parseEther("0.01");
export const MAX_FACTOR = ethers.parseEther("100");

// Tolerance for floating point comparisons
export const DEFAULT_TOLERANCE = ethers.parseEther("0.00000001"); // 1e-8 WAD
export const LOOSE_TOLERANCE = ethers.parseEther("0.0001"); // 1e-4 WAD

// Time constants
export const ONE_DAY = 86400;
export const ONE_HOUR = 3600;

// Phase 7: Create uniform prior factors (all 1 WAD)
// Use this for createMarket calls to get ΔEₜ = 0
export function uniformFactors(numBins: number): bigint[] {
  return Array(numBins).fill(WAD);
}
