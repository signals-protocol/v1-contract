import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  SignalsCoreHarness,
  SignalsCore,
  SignalsPosition,
  SignalsLPShare,
  TestERC1967Proxy,
  MockFeePolicy,
  LPVaultModule,
  OracleModule,
} from "../../../typechain-types";

const FEED_ID = ethers.encodeBytes32String("BTC");
const FEED_DECIMALS = 8;
const MAX_SAMPLE_DISTANCE = 600n;
const FUTURE_TOLERANCE = 60n;
const WAD = ethers.parseEther("1");

describe("Dev Batch Bypass: setCurrentBatchId + resetBatchProcessed", () => {
  async function setup() {
    const [owner, nonOwner] = await ethers.getSigners();
    const payment = await (
      await ethers.getContractFactory("SignalsUSDToken")
    ).deploy();
    const positionImpl = await (
      await ethers.getContractFactory("SignalsPosition")
    ).deploy();
    const lazyLib = await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy();

    const tradeModule = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const lifecycleModule = (await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as MarketLifecycleModule;
    const oracleModule = (await (
      await ethers.getContractFactory("OracleModuleHarness")
    ).deploy()) as OracleModule;
    const riskModule = await (
      await ethers.getContractFactory("RiskModule")
    ).deploy();
    const vaultModule = (await (
      await ethers.getContractFactory("LPVaultModule")
    ).deploy()) as LPVaultModule;

    const coreImpl = (await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as SignalsCoreHarness;

    const submitWindow = 300;
    const opsWindow = 60;
    const claimDelay = submitWindow + opsWindow;

    const lpShareImpl = await (
      await ethers.getContractFactory("SignalsLPShare")
    ).deploy();

    const proxyFactory = await ethers.getContractFactory("TestERC1967Proxy");
    const positionProxy = (await proxyFactory.deploy(
      positionImpl.target,
      "0x"
    )) as TestERC1967Proxy;
    const lpShareProxy = (await proxyFactory.deploy(
      lpShareImpl.target,
      "0x"
    )) as TestERC1967Proxy;
    const coreProxy = (await proxyFactory.deploy(
      coreImpl.target,
      "0x"
    )) as TestERC1967Proxy;

    const position = (await ethers.getContractAt(
      "SignalsPosition",
      await positionProxy.getAddress()
    )) as SignalsPosition;
    const lpShare = (await ethers.getContractAt(
      "SignalsLPShare",
      await lpShareProxy.getAddress()
    )) as SignalsLPShare;
    const core = (await ethers.getContractAt(
      "SignalsCoreHarness",
      await coreProxy.getAddress()
    )) as SignalsCoreHarness;

    const feePolicy = (await (
      await ethers.getContractFactory("MockFeePolicy")
    ).deploy(0)) as MockFeePolicy;

    const coreParams: SignalsCore.InitParamsStruct = {
      paymentToken: payment.target.toString(),
      positionContract: await position.getAddress(),
      lpShareToken: await lpShare.getAddress(),
      tradeModule: tradeModule.target.toString(),
      lifecycleModule: lifecycleModule.target.toString(),
      riskModule: riskModule.target.toString(),
      vaultModule: vaultModule.target.toString(),
      oracleModule: oracleModule.target.toString(),
      ownerSafe: owner.address,
      settlementSubmitWindow: submitWindow,
      pendingOpsWindow: opsWindow,
      claimDelaySeconds: claimDelay,
      redstoneFeedId: FEED_ID,
      redstoneFeedDecimals: FEED_DECIMALS,
      maxSampleDistance: MAX_SAMPLE_DISTANCE,
      futureTolerance: FUTURE_TOLERANCE,
      lambda: ethers.parseEther("0.3"),
      kDrawdown: ethers.parseEther("1"),
      enforceAlpha: false,
      rhoBS: 0,
      phiLP: WAD,
      phiBS: 0,
      phiTR: 0,
      withdrawalLagBatches: 1,
      operatorAllowlist: [owner.address],
    };
    await core.initialize(coreParams);
    await position.initialize(await core.getAddress(), owner.address);
    await lpShare.initialize(
      await core.getAddress(),
      payment.target.toString(),
      "Signals LP",
      "SIGLP",
      owner.address
    );

    return {
      owner,
      nonOwner,
      payment,
      position,
      core,
      feePolicy,
      submitWindow,
      opsWindow,
      claimDelay,
    };
  }

  // ============================================================
  // setCurrentBatchId
  // ============================================================

  describe("setCurrentBatchId", () => {
    it("owner can set currentBatchId", async () => {
      const { core } = await setup();
      await core.setCurrentBatchId(42);
      expect(await core.getCurrentBatchId()).to.equal(42);
    });

    it("non-owner reverts", async () => {
      const { core, nonOwner } = await setup();
      await expect(
        core.connect(nonOwner).setCurrentBatchId(42)
      ).to.be.revertedWithCustomError(core, "OwnableUnauthorizedAccount");
    });

    it("rolling back enables createMarket in past batch", async () => {
      const { core, feePolicy } = await setup();

      // Create a market in a future batch first to advance currentBatchId
      const now = BigInt(await time.latest());
      const futureSettlement = now + 200n;
      await core.createMarketUniform(
        0, 4, 1,
        Number(now - 10n),
        Number(now + 100n),
        Number(futureSettlement),
        4,
        WAD,
        feePolicy.target.toString()
      );

      // Advance time and process batch to move currentBatchId forward
      // Instead, let's just set currentBatchId high manually via harness
      // then roll it back
      const highBatchId = 30000n; // far future
      await core.setCurrentBatchId(highBatchId);
      expect(await core.getCurrentBatchId()).to.equal(highBatchId);

      // Now creating a market with settlement in the past should fail
      const pastSettlement = now + 10n;
      await expect(
        core.createMarketUniform(
          0, 4, 1,
          Number(now - 50n),
          Number(now - 5n),
          Number(pastSettlement),
          4,
          WAD,
          feePolicy.target.toString()
        )
      ).to.be.revertedWithCustomError(core, "BatchAlreadyProcessed");

      // Roll back currentBatchId to 0
      await core.setCurrentBatchId(0);
      expect(await core.getCurrentBatchId()).to.equal(0);

      // Now the same market creation should succeed
      await expect(
        core.createMarketUniform(
          0, 4, 1,
          Number(now - 50n),
          Number(now - 5n),
          Number(pastSettlement),
          4,
          WAD,
          feePolicy.target.toString()
        )
      ).to.not.be.reverted;
    });

    it("rolling back enables updateMarketTiming to past batch", async () => {
      const { core, feePolicy } = await setup();

      const now = BigInt(await time.latest());
      // Create market in future
      const futureSettlement = now + 500n;
      await core.createMarketUniform(
        0, 4, 1,
        Number(now - 10n),
        Number(now + 400n),
        Number(futureSettlement),
        4,
        WAD,
        feePolicy.target.toString()
      );
      const marketId = 1;

      // Set currentBatchId high
      await core.setCurrentBatchId(30000);

      // updateMarketTiming to past should fail
      const pastSettlement = now - 100n;
      await expect(
        core.updateMarketTiming(
          marketId,
          Number(now - 200n),
          Number(now - 150n),
          Number(pastSettlement)
        )
      ).to.be.revertedWithCustomError(core, "BatchAlreadyProcessed");

      // Roll back
      await core.setCurrentBatchId(0);

      // Now should succeed
      await expect(
        core.updateMarketTiming(
          marketId,
          Number(now - 200n),
          Number(now - 150n),
          Number(pastSettlement)
        )
      ).to.not.be.reverted;
    });
  });

  // ============================================================
  // resetBatchProcessed
  // ============================================================

  describe("resetBatchProcessed", () => {
    it("owner can reset batch processed flag", async () => {
      const { core, feePolicy, owner, payment } = await setup();

      // Seed vault so batch processing works
      await payment.mint(owner.address, ethers.parseUnits("100000", 6));
      await payment.approve(await core.getAddress(), ethers.parseUnits("100000", 6));
      await core.seedVault(ethers.parseUnits("10000", 6));

      // Fund backstop for batch processing
      await core.fundBackstop(ethers.parseUnits("5000", 6));

      // Create and settle a market
      const now = BigInt(await time.latest());
      const settlement = now + 200n;
      await core.createMarketUniform(
        0, 4, 1,
        Number(now - 10n),
        Number(now + 100n),
        Number(settlement),
        4,
        WAD,
        feePolicy.target.toString()
      );

      // Advance to settlement, mark failed, finalize secondary
      await time.increaseTo(Number(settlement) + 301);
      await core.markSettlementFailed(1);
      await core.finalizeSecondarySettlement(1, 2000000);

      // Process the batch
      const batchId = await core.getCurrentBatchId();

      // Verify resetBatchProcessed clears input fields and processed flag
      await expect(core.resetBatchProcessed(batchId)).to.not.be.reverted;

      // Verify the batch can accept new settlements (proves DeltaEtSum was cleared)
      // Re-settle: create another market, settle it to the same batch
      const now2 = BigInt(await time.latest());
      const settlement2 = now2 + 200n;
      await core.createMarketUniform(
        0, 4, 1,
        Number(now2 - 10n),
        Number(now2 + 100n),
        Number(settlement2),
        4,
        WAD,
        feePolicy.target.toString()
      );
      await time.increaseTo(Number(settlement2) + 301);
      await core.markSettlementFailed(2);
      // If DeltaEtSum wasn't cleared, this would revert with BatchDeltaEtExceedsBackstop
      await expect(core.finalizeSecondarySettlement(2, 2000000)).to.not.be.reverted;
    });

    it("non-owner reverts", async () => {
      const { core, nonOwner } = await setup();
      await expect(
        core.connect(nonOwner).resetBatchProcessed(42)
      ).to.be.revertedWithCustomError(core, "OwnableUnauthorizedAccount");
    });
  });

  // ============================================================
  // Regression: flag off (default) preserves existing validation
  // ============================================================

  describe("regression: default behavior unchanged", () => {
    it("createMarket still reverts on past batch without bypass", async () => {
      const { core, feePolicy } = await setup();

      // Set currentBatchId high (simulating batches have progressed)
      await core.setCurrentBatchId(30000);

      const now = BigInt(await time.latest());
      await expect(
        core.createMarketUniform(
          0, 4, 1,
          Number(now - 50n),
          Number(now - 5n),
          Number(now + 10n),
          4,
          WAD,
          feePolicy.target.toString()
        )
      ).to.be.revertedWithCustomError(core, "BatchAlreadyProcessed");
    });

    it("updateMarketTiming still reverts on past batch without bypass", async () => {
      const { core, feePolicy } = await setup();

      const now = BigInt(await time.latest());
      await core.createMarketUniform(
        0, 4, 1,
        Number(now - 10n),
        Number(now + 400n),
        Number(now + 500n),
        4,
        WAD,
        feePolicy.target.toString()
      );

      // Advance currentBatchId
      await core.setCurrentBatchId(30000);

      await expect(
        core.updateMarketTiming(
          1,
          Number(now - 200n),
          Number(now - 150n),
          Number(now - 100n)
        )
      ).to.be.revertedWithCustomError(core, "BatchAlreadyProcessed");
    });
  });
});
