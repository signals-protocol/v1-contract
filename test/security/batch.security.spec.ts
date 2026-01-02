import { expect } from "chai";
import { ethers } from "hardhat";
import { time, loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { USDC_DECIMALS, batchEndTimestamp } from "../helpers/constants";

/**
 * Batch Processing Security Tests
 * 
 * Tests for:
 * - Future batch processing prevention
 * - Batch access control
 */
describe("Batch Processing Security", () => {
  async function deployBatchFixture() {
    const [owner, user1] = await ethers.getSigners();

    const payment = await (await ethers.getContractFactory("SignalsUSDToken")).deploy();
    const fundAmount = ethers.parseUnits("1000000", USDC_DECIMALS);
    await payment.transfer(user1.address, fundAmount);

    const positionImpl = await (await ethers.getContractFactory("SignalsPosition")).deploy();
    const positionInit = positionImpl.interface.encodeFunctionData("initialize", [owner.address]);
    const positionProxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(
      positionImpl.target,
      positionInit
    );
    const position = await ethers.getContractAt("SignalsPosition", positionProxy.target);

    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();

    const oracleModule = await (await ethers.getContractFactory("OracleModuleHarness")).deploy();
    const tradeModule = await (await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target }
    })).deploy();
    const lifecycleModule = await (await ethers.getContractFactory("MarketLifecycleModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target }
    })).deploy();
    const lpVaultModule = await (await ethers.getContractFactory("LPVaultModule")).deploy();
    const riskModule = await (await ethers.getContractFactory("RiskModule")).deploy();

    const coreImpl = await (await ethers.getContractFactory("SignalsCoreHarness", {
      libraries: { LazyMulSegmentTree: lazyLib.target }
    })).deploy();
    const coreInit = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      3600, // settlementSubmitWindow
      3600  // settlementFinalizeDeadline
    ]);
    const coreProxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(
      coreImpl.target,
      coreInit
    );
    const core = await ethers.getContractAt("SignalsCoreHarness", coreProxy.target);

    // Deploy LP Share with core address
    const lpShare = await (await ethers.getContractFactory("SignalsLPShare")).deploy(
      "Signals LP Share",
      "sLP",
      core.target,
      payment.target
    );

    await core.setModules(
      tradeModule.target,
      lifecycleModule.target,
      riskModule.target,
      lpVaultModule.target,
      oracleModule.target
    );

    await core.setLpShareToken(lpShare.target);

    const feedId = ethers.encodeBytes32String("BTC");
    await core.setRedstoneConfig(
      feedId,
      8,
      600,  // maxSampleDistance
      60    // futureTolerance
    );

    // Configure risk and fee waterfall (required for batch processing)
    await core.setRiskConfig(
      ethers.parseEther("0.2"),   // lambda
      ethers.parseEther("1"),     // kDrawdown
      false                       // enforceAlpha
    );
    await core.setFeeWaterfallConfig(
      0n,                         // rhoBS
      ethers.parseEther("0.7"),   // phiLP
      ethers.parseEther("0.2"),   // phiBS
      ethers.parseEther("0.1")    // phiTR
    );

    await position.setCore(core.target);

    await payment.connect(user1).approve(core.target, ethers.MaxUint256);
    await payment.connect(owner).approve(core.target, ethers.MaxUint256);

    // Seed vault
    await core.connect(owner).seedVault(ethers.parseUnits("100000", USDC_DECIMALS));

    return { core, payment, owner, user1, lpVaultModule };
  }

  async function seedBatchForProcessing(core: any, batchId: bigint) {
    await core.harnessSetBatchMarketState(batchId, 1n, 1n);
  }
  
  describe("Batch Timing & Access", () => {
    it("allows processing batch even before its time period ends", async () => {
      const { core, owner } = await loadFixture(deployBatchFixture);
      
      const currentBatchId = await core.currentBatchId();
      const nextBatchId = currentBatchId + 1n;
      
      await seedBatchForProcessing(core, nextBatchId);
      
      await expect(
        core.connect(owner).processDailyBatch(nextBatchId)
      ).to.not.be.reverted;
    });

    it("reverts processing batch with no assigned markets", async () => {
      const { core, owner, lpVaultModule } = await loadFixture(deployBatchFixture);

      const currentBatchId = await core.currentBatchId();
      const nextBatchId = currentBatchId + 1n;
      const batchEndTime = batchEndTimestamp(nextBatchId);

      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);

      await expect(
        core.connect(owner).processDailyBatch(nextBatchId)
      ).to.be.revertedWithCustomError(lpVaultModule, "BatchHasNoMarkets")
        .withArgs(nextBatchId);
    });
    
    it("prevents non-owner from processing batch", async () => {
      const { core, owner, user1 } = await loadFixture(deployBatchFixture);
      
      const currentBatchId = await core.currentBatchId();
      const nextBatchId = currentBatchId + 1n;
      
      await seedBatchForProcessing(core, nextBatchId);
      
      await expect(
        core.connect(user1).processDailyBatch(nextBatchId)
      ).to.be.revertedWithCustomError(core, "OwnableUnauthorizedAccount");
      
      await expect(
        core.connect(owner).processDailyBatch(nextBatchId)
      ).to.not.be.reverted;
    });
  });
  
  describe("Batch Sequence Enforcement", () => {
    it("reverts processing out-of-sequence batch", async () => {
      const { core, owner, lpVaultModule } = await loadFixture(deployBatchFixture);
      
      const currentBatchId = await core.currentBatchId();
      const farFutureBatchId = currentBatchId + 5n;
      
      // Set time far in future
      const farFutureBatchEnd = batchEndTimestamp(farFutureBatchId);
      await time.setNextBlockTimestamp(Number(farFutureBatchEnd) + 1);
      
      // Try to skip batches - should fail
      await expect(
        core.connect(owner).processDailyBatch(farFutureBatchId)
      ).to.be.revertedWithCustomError(lpVaultModule, "BatchNotReady");
    });
    
    it("processes batches sequentially", async () => {
      const { core, owner } = await loadFixture(deployBatchFixture);
      
      const startBatchId = await core.currentBatchId();
      
      // Process 3 batches sequentially
      for (let i = 1n; i <= 3n; i++) {
        const batchId = startBatchId + i;
        const batchEndTime = batchEndTimestamp(batchId);
        
        await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
        await seedBatchForProcessing(core, batchId);
        await core.connect(owner).processDailyBatch(batchId);
        
        expect(await core.currentBatchId()).to.equal(batchId);
      }
    });
  });
  
  describe("Double Processing Prevention", () => {
    it("reverts processing same batch twice", async () => {
      const { core, owner, lpVaultModule } = await loadFixture(deployBatchFixture);
      
      const currentBatchId = await core.currentBatchId();
      const nextBatchId = currentBatchId + 1n;
      const batchEndTime = batchEndTimestamp(nextBatchId);
      
      // Process batch once
      await time.setNextBlockTimestamp(Number(batchEndTime) + 1);
      await seedBatchForProcessing(core, nextBatchId);
      await core.connect(owner).processDailyBatch(nextBatchId);
      
      // Try to process again
      await expect(
        core.connect(owner).processDailyBatch(nextBatchId)
      ).to.be.revertedWithCustomError(lpVaultModule, "BatchNotReady");
    });
  });
});
