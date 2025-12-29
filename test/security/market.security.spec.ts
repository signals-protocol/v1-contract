import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { WAD, USDC_DECIMALS } from "../helpers/constants";
import { deploySeedData } from "../helpers";

/**
 * Market Security Tests
 *
 * Tests for:
 * - numBins hard cap enforcement (Diff array O(n) pointQuery protection)
 * - Market parameter validation
 */
describe("Market Security", () => {
  async function deploySeed(numBins: number, factors?: bigint[]) {
    const seedFactors = factors ?? Array(numBins).fill(WAD);
    return deploySeedData(seedFactors);
  }

  async function deployMarketFixture() {
    const [owner, user1] = await ethers.getSigners();

    const payment = await (
      await ethers.getContractFactory("SignalsUSDToken")
    ).deploy();
    const fundAmount = ethers.parseUnits("1000000", USDC_DECIMALS);
    await payment.transfer(user1.address, fundAmount);

    const positionImpl = await (
      await ethers.getContractFactory("SignalsPosition")
    ).deploy();
    const positionInit = positionImpl.interface.encodeFunctionData(
      "initialize",
      [owner.address]
    );
    const positionProxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(positionImpl.target, positionInit);
    const position = await ethers.getContractAt(
      "SignalsPosition",
      positionProxy.target
    );

    const feePolicy = await (
      await ethers.getContractFactory("MockFeePolicy")
    ).deploy(0);
    const lazyLib = await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy();

    const oracleModule = await (
      await ethers.getContractFactory("OracleModuleHarness")
    ).deploy();
    const tradeModule = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const lifecycleModule = await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const lpVaultModule = await (
      await ethers.getContractFactory("LPVaultModule")
    ).deploy();
    const riskModule = await (
      await ethers.getContractFactory("RiskModule")
    ).deploy();

    const coreImpl = await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const coreInit = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      3600, // settlementSubmitWindow
      3600, // settlementFinalizeDeadline
    ]);
    const coreProxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(coreImpl.target, coreInit);
    const core = await ethers.getContractAt(
      "SignalsCoreHarness",
      coreProxy.target
    );

    const lpShare = await (
      await ethers.getContractFactory("SignalsLPShare")
    ).deploy("Signals LP Share", "sLP", core.target, payment.target);

    await core.setModules(
      tradeModule.target,
      lifecycleModule.target,
      riskModule.target,
      lpVaultModule.target,
      oracleModule.target
    );
    await core.setLpShareToken(lpShare.target);

    const feedId = ethers.encodeBytes32String("BTC");
    await core.setRedstoneConfig(feedId, 8, 600, 60);

    await core.setRiskConfig(
      ethers.parseEther("0.2"),
      ethers.parseEther("1"),
      false
    );
    await core.setFeeWaterfallConfig(
      0n,
      ethers.parseEther("0.8"),
      ethers.parseEther("0.1"),
      ethers.parseEther("0.1")
    );

    await position.setCore(core.target);
    await payment.connect(user1).approve(core.target, ethers.MaxUint256);
    await payment.connect(owner).approve(core.target, ethers.MaxUint256);
    await core.connect(owner).seedVault(ethers.parseUnits("100000", USDC_DECIMALS));

    return { core, payment, owner, user1, feePolicy, lifecycleModule };
  }

  describe("numBins Hard Cap", () => {
    it("rejects market creation with numBins = 0", async () => {
      const { core, owner, feePolicy, lifecycleModule } = await loadFixture(
        deployMarketFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Try to create market with 0 bins
      const numBins = 0;
      const minTick = 0;
      const maxTick = 10;
      const tickSpacing = 1;

      const factors: bigint[] = []; // Empty for 0 bins
      const seedData = await deploySeed(numBins, factors);

      await expect(
        core.connect(owner).createMarket(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target,
          await seedData.getAddress()
        )
      ).to.be.revertedWithCustomError(lifecycleModule, "BinCountExceedsLimit");
    });

    it("rejects market creation with numBins > 256", async () => {
      const { core, owner, feePolicy, lifecycleModule } = await loadFixture(
        deployMarketFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Try to create market with 257 bins (exceeds 256 cap)
      const numBins = 257;
      const minTick = 0;
      const maxTick = numBins; // maxTick = minTick + numBins * tickSpacing
      const tickSpacing = 1;

      const seedData = await deploySeed(numBins);

      await expect(
        core.connect(owner).createMarket(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target,
          await seedData.getAddress()
        )
      ).to.be.revertedWithCustomError(lifecycleModule, "BinCountExceedsLimit");
    });

    it("allows market creation with numBins = 256", async () => {
      const { core, owner, feePolicy } = await loadFixture(deployMarketFixture);

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Create market with exactly 256 bins (at the limit)
      const numBins = 256;
      const minTick = 0;
      const maxTick = numBins;
      const tickSpacing = 1;

      const factors = Array(numBins).fill(WAD);
      const seedData = await deploySeed(numBins, factors);

      await expect(
        core.connect(owner).createMarket(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target,
          await seedData.getAddress()
        )
      ).to.not.be.reverted;
    });

    it("allows market creation with numBins = 100 (typical use case)", async () => {
      const { core, owner, feePolicy } = await loadFixture(deployMarketFixture);

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Create market with 100 bins (typical use case)
      const numBins = 100;
      const minTick = 0;
      const maxTick = numBins;
      const tickSpacing = 1;

      const factors = Array(numBins).fill(WAD);
      const seedData = await deploySeed(numBins, factors);

      await expect(
        core.connect(owner).createMarket(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target,
          await seedData.getAddress()
        )
      ).to.not.be.reverted;
    });

    it("allows market creation with numBins = 2 (minimum valid)", async () => {
      const { core, owner, feePolicy } = await loadFixture(deployMarketFixture);

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Create market with 2 bins (minimum valid per RiskMath: numBins > 1)
      const numBins = 2;
      const minTick = 0;
      const maxTick = numBins;
      const tickSpacing = 1;

      const factors = Array(numBins).fill(WAD);
      const seedData = await deploySeed(numBins, factors);

      await expect(
        core.connect(owner).createMarket(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target,
          await seedData.getAddress()
        )
      ).to.not.be.reverted;
    });

    it("rejects market with large numBins that would DoS settlement", async () => {
      const { core, owner, feePolicy, lifecycleModule } = await loadFixture(
        deployMarketFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Try to create market with 1000 bins (would DoS pointQuery)
      const numBins = 1000;
      const minTick = 0;
      const maxTick = numBins;
      const tickSpacing = 1;

      const seedData = await deploySeed(256);

      await expect(
        core.connect(owner).createMarket(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target,
          await seedData.getAddress()
        )
      ).to.be.revertedWithCustomError(core, "SeedDataLengthMismatch");
    });
  });

  describe("createMarketUniform also enforces cap", () => {
    it("rejects uniform market with numBins = 0", async () => {
      const { core, owner, feePolicy, lifecycleModule } = await loadFixture(
        deployMarketFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Try to create uniform market with 0 bins
      const numBins = 0;
      const minTick = 0;
      const maxTick = 10;
      const tickSpacing = 1;

      await expect(
        core.connect(owner).createMarketUniform(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target
        )
      ).to.be.revertedWithCustomError(lifecycleModule, "BinCountExceedsLimit");
    });

    it("rejects uniform market with numBins > 256", async () => {
      const { core, owner, feePolicy, lifecycleModule } = await loadFixture(
        deployMarketFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;

      // Try to create uniform market with 300 bins
      const numBins = 300;
      const minTick = 0;
      const maxTick = numBins;
      const tickSpacing = 1;

      await expect(
        core.connect(owner).createMarketUniform(
          minTick,
          maxTick,
          tickSpacing,
          now - 100,
          now + 10000,
          now + 10100,
          numBins,
          WAD,
          feePolicy.target
        )
      ).to.be.revertedWithCustomError(lifecycleModule, "BinCountExceedsLimit");
    });
  });
});
