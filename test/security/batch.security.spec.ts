import { expect } from "chai";
import { ethers } from "hardhat";
import { time, loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { SignalsCore } from '../../typechain-types';
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
    const [owner, user1, user2] = await ethers.getSigners();

    const payment = await (await ethers.getContractFactory("SignalsUSDToken")).deploy();
    const fundAmount = ethers.parseUnits("1000000", USDC_DECIMALS);
    await payment.transfer(user1.address, fundAmount);
    await payment.transfer(user2.address, fundAmount);
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
    const positionImpl = await (await ethers.getContractFactory("SignalsPosition")).deploy();
    const lpShareImpl = await (await ethers.getContractFactory("SignalsLPShare")).deploy();
    const proxyFactory = await ethers.getContractFactory("TestERC1967Proxy");
    const positionProxy = await proxyFactory.deploy(positionImpl.target, "0x");
    const lpShareProxy = await proxyFactory.deploy(lpShareImpl.target, "0x");
    const coreProxy = await proxyFactory.deploy(coreImpl.target, "0x");
    const position = await ethers.getContractAt("SignalsPosition", await positionProxy.getAddress());
    const lpShare = await ethers.getContractAt("SignalsLPShare", await lpShareProxy.getAddress());
    const core = await ethers.getContractAt("SignalsCoreHarness", await coreProxy.getAddress());

    const feedId = ethers.encodeBytes32String("BTC");
    const submitWindow = 3600;
    const opsWindow = 3600;
    const claimDelay = submitWindow + opsWindow;
    const coreParams: SignalsCore.InitParamsStruct = {
      paymentToken: payment.target.toString(),
      positionContract: await position.getAddress(),
      lpShareToken: await lpShare.getAddress(),
      tradeModule: tradeModule.target.toString(),
      lifecycleModule: lifecycleModule.target.toString(),
      riskModule: riskModule.target.toString(),
      vaultModule: lpVaultModule.target.toString(),
      oracleModule: oracleModule.target.toString(),
      ownerSafe: owner.address,
      settlementSubmitWindow: submitWindow,
      pendingOpsWindow: opsWindow,
      claimDelaySeconds: claimDelay,
      redstoneFeedId: feedId,
      redstoneFeedDecimals: 8,
      maxSampleDistance: 600,
      futureTolerance: 60,
      lambda: ethers.parseEther("0.2"),
      kDrawdown: ethers.parseEther("1"),
      enforceAlpha: false,
      rhoBS: 0n,
      phiLP: ethers.parseEther("0.7"),
      phiBS: ethers.parseEther("0.2"),
      phiTR: ethers.parseEther("0.1"),
      withdrawalLagBatches: 0,
      operatorAllowlist: [owner.address],
    };
    await core.initialize(coreParams);
    await position.initialize(await core.getAddress(), owner.address);
    await lpShare.initialize(
      await core.getAddress(),
      payment.target.toString(),
      "Signals LP Share",
      "sLP",
      owner.address
    );

    await payment.connect(user1).approve(core.target, ethers.MaxUint256);
    await payment.connect(user2).approve(core.target, ethers.MaxUint256);
    await payment.connect(owner).approve(core.target, ethers.MaxUint256);

    // Seed vault
    await core.connect(owner).seedVault(ethers.parseUnits("100000", USDC_DECIMALS));

    return { core, payment, owner, user1, user2, lpVaultModule };
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
    
    it("allows owner or operator, rejects non-operator", async () => {
      const { core, owner, user1, user2 } = await loadFixture(deployBatchFixture);
      
      const currentBatchId = await core.currentBatchId();
      const nextBatchId = currentBatchId + 1n;
      
      await seedBatchForProcessing(core, nextBatchId);
      
      await expect(
        core.connect(user2).processDailyBatch(nextBatchId)
      ).to.be.revertedWithCustomError(core, "UnauthorizedCaller").withArgs(user2.address);

      await core.connect(owner).setOperator(user1.address, true);

      await expect(
        core.connect(user1).processDailyBatch(nextBatchId)
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
