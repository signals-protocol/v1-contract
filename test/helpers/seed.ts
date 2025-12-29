import { BigNumberish } from "ethers";
import { ethers } from "hardhat";
import { SeedData } from "../../typechain-types";

export function packFactors(factors: readonly BigNumberish[]): string {
  if (factors.length === 0) {
    return "0x";
  }

  const types = new Array(factors.length).fill("uint256");
  return ethers.solidityPacked(types, factors);
}

export async function deploySeedData(
  factors: readonly BigNumberish[]
): Promise<SeedData> {
  const packed = packFactors(factors);
  const factory = await ethers.getContractFactory("SeedData");
  const seedData = (await factory.deploy(packed)) as SeedData;
  await seedData.waitForDeployment();
  return seedData;
}
