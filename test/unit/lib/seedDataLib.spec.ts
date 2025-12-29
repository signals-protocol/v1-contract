import { expect } from "chai";
import { ethers } from "hardhat";
import { SeedDataLibHarness } from "../../../typechain-types";
import { deploySeedData } from "../../helpers";

describe("SeedDataLib", () => {
  let harness: SeedDataLibHarness;
  const WAD = ethers.parseEther("1");

  beforeEach(async () => {
    const factory = await ethers.getContractFactory("SeedDataLibHarness");
    harness = (await factory.deploy()) as SeedDataLibHarness;
  });

  it("reads factors by range", async () => {
    const factors = [WAD, 2n * WAD, 3n * WAD, 4n * WAD];
    const seedData = await deploySeedData(factors);

    const slice = await harness.readFactors(seedData.target, 1, 2);
    expect(slice).to.deep.equal([2n * WAD, 3n * WAD]);

    const empty = await harness.readFactors(seedData.target, 0, 0);
    expect(empty).to.deep.equal([]);
  });

  it("rejects zero address in validateSeedData", async () => {
    await expect(
      harness.validateSeedData(ethers.ZeroAddress, 4)
    ).to.be.revertedWithCustomError(harness, "ZeroAddress");
  });

  it("rejects size mismatch in validateSeedData", async () => {
    const seedData = await deploySeedData(Array(4).fill(WAD));
    await expect(
      harness.validateSeedData(seedData.target, 5)
    ).to.be.revertedWithCustomError(harness, "SeedDataLengthMismatch")
      .withArgs(4 * 32, 5 * 32);
  });

  it("computes rootSum/minFactor/ΔEₜ for uniform prior", async () => {
    const numBins = 4;
    const alpha = ethers.parseEther("100");
    const seedData = await deploySeedData(Array(numBins).fill(WAD));

    const [rootSum, minFactor, deltaEt] = await harness.computeSeedStats(
      seedData.target,
      numBins,
      alpha
    );

    expect(rootSum).to.equal(BigInt(numBins) * WAD);
    expect(minFactor).to.equal(WAD);
    expect(deltaEt).to.equal(0n);
  });

  it("computes ΔEₜ consistent with RiskMath for skewed prior", async () => {
    const numBins = 4;
    const alpha = ethers.parseEther("100");
    const factors = [2n * WAD, WAD, WAD, WAD];
    const seedData = await deploySeedData(factors);

    const [rootSum, minFactor, deltaEt] = await harness.computeSeedStats(
      seedData.target,
      numBins,
      alpha
    );

    expect(rootSum).to.equal(5n * WAD);
    expect(minFactor).to.equal(WAD);

    const expectedDelta = await harness.calculateDeltaEt(
      alpha,
      numBins,
      rootSum,
      minFactor
    );
    expect(deltaEt).to.equal(expectedDelta);
    expect(deltaEt).to.be.gt(0n);
  });

  it("reverts when factors contain zero", async () => {
    const numBins = 4;
    const alpha = ethers.parseEther("100");
    const factors = [WAD, 0n, WAD, WAD];
    const seedData = await deploySeedData(factors);

    await expect(
      harness.computeSeedStats(seedData.target, numBins, alpha)
    ).to.be.revertedWithCustomError(harness, "InvalidFactor")
      .withArgs(0);
  });
});
