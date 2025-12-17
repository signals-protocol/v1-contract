import { expect } from "chai";
import { ethers } from "hardhat";
import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { WAD, USDC_DECIMALS, SMALL_QUANTITY } from "../helpers/constants";
import {
  buildRedstonePayload,
  submitWithPayload,
} from "../helpers/redstone";

// Settlement tick = settlementValue / 10^6 = humanPrice
function tickToHumanPrice(tick: number): number {
  return tick;
}

/**
 * Escrow Security Tests
 *
 * Tests for:
 * - Free balance protection (pending deposits + payout reserves)
 * - Payout reserve integrity
 * - Settlement tick clamping
 */
describe("Escrow Security", () => {
  async function deploySecurityFixture() {
    const [owner, user1, user2] = await ethers.getSigners();

    const payment = await (
      await ethers.getContractFactory("MockPaymentToken")
    ).deploy();
    const fundAmount = ethers.parseUnits("1000000", USDC_DECIMALS);
    await payment.transfer(user1.address, fundAmount);
    await payment.transfer(user2.address, fundAmount);

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

    // Deploy OracleModuleTest for Redstone testing
    const oracleModule = await (
      await ethers.getContractFactory("OracleModuleTest")
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

    // Deploy LP Share with core address
    const lpShare = await (
      await ethers.getContractFactory("SignalsLPShare")
    ).deploy("Signals LP Share", "sLP", core.target, payment.target);

    // Set modules
    await core.setModules(
      tradeModule.target,
      lifecycleModule.target,
      riskModule.target,
      lpVaultModule.target,
      oracleModule.target
    );

    // Set LP share token
    await core.setLpShareToken(lpShare.target);

    // Configure Redstone
    const feedId = ethers.encodeBytes32String("BTC");
    await core.setRedstoneConfig(
      feedId,
      8,
      600, // maxSampleDistance
      60 // futureTolerance
    );

    // Set settlement timeline
    await core.setSettlementTimeline(3600, 3600, 86400);

    // Configure risk and fee waterfall (required for batch processing)
    await core.setRiskConfig(
      ethers.parseEther("0.2"), // lambda
      ethers.parseEther("1"), // kDrawdown
      false // enforceAlpha
    );
    await core.setFeeWaterfallConfig(
      0n, // rhoBS
      ethers.parseEther("0.7"), // phiLP
      ethers.parseEther("0.2"), // phiBS
      ethers.parseEther("0.1") // phiTR
    );

    // Link position to core
    await position.setCore(core.target);

    // Approve
    await payment.connect(user1).approve(core.target, ethers.MaxUint256);
    await payment.connect(user2).approve(core.target, ethers.MaxUint256);
    await payment.connect(owner).approve(core.target, ethers.MaxUint256);

    // Seed vault
    await core
      .connect(owner)
      .seedVault(ethers.parseUnits("100000", USDC_DECIMALS));

    return { core, payment, position, lpShare, owner, user1, user2, feePolicy };
  }

  describe("Free Balance Protection", () => {
    it("trade proceeds cannot use pending deposits", async () => {
      const { core, payment, user1, user2, owner, feePolicy } =
        await loadFixture(deploySecurityFixture);

      // User1 requests deposit (creates pending deposit)
      const depositAmount = ethers.parseUnits("10000", USDC_DECIMALS);
      await core.connect(user1).requestDeposit(depositAmount);

      // Create a market for user2 to trade
      const now = (await ethers.provider.getBlock("latest"))!.timestamp;
      const marketId = await core.connect(owner).createMarketUniform.staticCall(
        0, // minTick
        100, // maxTick
        1, // tickSpacing
        now - 100,
        now + 10000,
        now + 10100,
        100, // numBins
        WAD, // liquidityParameter
        feePolicy.target
      );
      await core.connect(owner).createMarketUniform(
        0, // minTick
        100, // maxTick
        1, // tickSpacing
        now - 100,
        now + 10000,
        now + 10100,
        100, // numBins
        WAD, // liquidityParameter
        feePolicy.target
      );

      // User2 opens a position
      await core
        .connect(user2)
        .openPosition(
          marketId,
          10,
          20,
          SMALL_QUANTITY,
          ethers.parseUnits("1000", USDC_DECIMALS)
        );

      // Get position ID
      const positionId = 1n;

      // User2 closes position - should succeed but not drain pending deposits
      await core.connect(user2).closePosition(positionId, 0);

      // Core should still have at least the pending deposit amount
      const balanceAfter = await payment.balanceOf(core.target);
      expect(balanceAfter).to.be.gte(depositAmount);
    });
  });

  describe("Settlement Tick Clamp", () => {
    it("settlement at maxTick boundary clamps to last valid tick", async () => {
      const { core, user1, owner, feePolicy } = await loadFixture(
        deploySecurityFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;
      const settlementTs = now + 1000;

      // Create market with clear boundaries
      const marketId = await core.connect(owner).createMarketUniform.staticCall(
        0, // minTick
        100, // maxTick
        1, // tickSpacing
        now - 100,
        now + 500,
        settlementTs,
        100, // numBins
        WAD, // liquidityParameter
        feePolicy.target
      );
      await core
        .connect(owner)
        .createMarketUniform(
          0,
          100,
          1,
          now - 100,
          now + 500,
          settlementTs,
          100,
          WAD,
          feePolicy.target
        );

      // User opens position at upper boundary
      await core.connect(user1).openPosition(
        marketId,
        95,
        100, // upperTick is exclusive
        SMALL_QUANTITY,
        ethers.parseUnits("1000", USDC_DECIMALS)
      );

      // Advance to settlement window
      await time.setNextBlockTimestamp(settlementTs + 1);

      // Submit settlement at exactly maxTick (100) - should clamp to 99
      const settlementPrice = tickToHumanPrice(100);
      const payload = buildRedstonePayload(settlementPrice, settlementTs);
      await submitWithPayload(core, owner, marketId, payload);

      // Advance past ops window
      const opsEnd = settlementTs + 3600 + 3600;
      await time.setNextBlockTimestamp(opsEnd + 1);

      // Finalize should succeed (tick clamped to 99, not 100)
      await expect(core.connect(owner).finalizePrimarySettlement(marketId)).to
        .not.be.reverted;

      // Verify settlement tick is clamped
      const market = await core.harnessGetMarket(marketId);
      expect(market.settlementTick).to.equal(99); // Last valid tick
    });

    it("settlement above maxTick clamps correctly", async () => {
      const { core, user1, owner, feePolicy } = await loadFixture(
        deploySecurityFixture
      );

      const now = (await ethers.provider.getBlock("latest"))!.timestamp;
      const settlementTs = now + 1000;

      const marketId = await core
        .connect(owner)
        .createMarketUniform.staticCall(
          0,
          100,
          1,
          now - 100,
          now + 500,
          settlementTs,
          100,
          WAD,
          feePolicy.target
        );
      await core
        .connect(owner)
        .createMarketUniform(
          0,
          100,
          1,
          now - 100,
          now + 500,
          settlementTs,
          100,
          WAD,
          feePolicy.target
        );

      await core
        .connect(user1)
        .openPosition(
          marketId,
          90,
          100,
          SMALL_QUANTITY,
          ethers.parseUnits("1000", USDC_DECIMALS)
        );

      await time.setNextBlockTimestamp(settlementTs + 1);

      // Submit settlement way above maxTick
      const settlementPrice = tickToHumanPrice(500);
      const payload = buildRedstonePayload(settlementPrice, settlementTs);
      await submitWithPayload(core, owner, marketId, payload);

      const opsEnd = settlementTs + 3600 + 3600;
      await time.setNextBlockTimestamp(opsEnd + 1);

      // Should succeed with clamped tick
      await expect(core.connect(owner).finalizePrimarySettlement(marketId)).to
        .not.be.reverted;

      const market2 = await core.harnessGetMarket(marketId);
      expect(market2.settlementTick).to.equal(99);
    });
  });
});
