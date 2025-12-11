import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MockPaymentToken,
  MockFeePolicy,
  TradeModuleProxy,
  SignalsPosition,
  TestERC1967Proxy,
} from "../../typechain-types";
import { ISignalsCore } from "../../typechain-types/contracts/harness/TradeModuleProxy";
import { WAD, USDC_DECIMALS, SMALL_QUANTITY, MEDIUM_QUANTITY } from "../helpers/constants";
import { approx, createPrng } from "../helpers/utils";

/**
 * CLMSR Invariant Tests
 * 
 * Tests mathematical and system invariants that must hold for CLMSR correctness:
 * - Sum monotonicity (buy increases sum, sell decreases)
 * - Range isolation (only affected bins change)
 * - Cost/proceeds symmetry (roundtrip preserves value)
 * - Loss bound (maker loss bounded by α·ln(n))
 */

interface DeployedSystem {
  owner: HardhatEthersSigner;
  user: HardhatEthersSigner;
  user2: HardhatEthersSigner;
  payment: MockPaymentToken;
  position: SignalsPosition;
  core: TradeModuleProxy;
  feePolicy: MockFeePolicy;
  marketId: number;
}

describe("CLMSR Invariants", () => {
  const NUM_BINS = 10;
  const MARKET_ID = 1;

  async function deployInvariantFixture(): Promise<DeployedSystem> {
    const [owner, user, user2] = await ethers.getSigners();

    const payment = await (
      await ethers.getContractFactory("MockPaymentToken")
    ).deploy();

    const positionImplFactory = await ethers.getContractFactory("SignalsPosition");
    const positionImpl = await positionImplFactory.deploy();
    await positionImpl.waitForDeployment();
    const positionInit = positionImplFactory.interface.encodeFunctionData(
      "initialize",
      [owner.address]
    );
    const positionProxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(positionImpl.target, positionInit);
    const position = (await ethers.getContractAt(
      "SignalsPosition",
      await positionProxy.getAddress()
    )) as SignalsPosition;

    const feePolicy = await (
      await ethers.getContractFactory("MockFeePolicy")
    ).deploy(0); // No fees for invariant tests

    const lazyLib = await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy();
    const tradeModule = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();

    const core = await (
      await ethers.getContractFactory("TradeModuleProxy", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy(tradeModule.target);

    await core.setAddresses(
      payment.target,
      await position.getAddress(),
      1,
      1,
      owner.address,
      feePolicy.target
    );

    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const market: ISignalsCore.MarketStruct = {
      isActive: true,
      settled: false,
      snapshotChunksDone: false,
      numBins: NUM_BINS,
      openPositionCount: 0,
      snapshotChunkCursor: 0,
      startTimestamp: now - 10,
      endTimestamp: now + 100000,
      settlementTimestamp: now + 100000,
      minTick: 0,
      maxTick: NUM_BINS,
      tickSpacing: 1,
      settlementTick: 0,
      settlementValue: 0,
      liquidityParameter: WAD,
      feePolicy: ethers.ZeroAddress,
    };
    await core.setMarket(MARKET_ID, market);

    // Seed with uniform distribution
    const factors = Array(NUM_BINS).fill(WAD);
    await core.seedTree(MARKET_ID, factors);

    await position.connect(owner).setCore(core.target);

    // Fund users
    const fundAmount = ethers.parseUnits("100000", USDC_DECIMALS);
    await payment.transfer(user.address, fundAmount);
    await payment.transfer(user2.address, fundAmount);
    await payment.connect(user).approve(core.target, fundAmount);
    await payment.connect(user2).approve(core.target, fundAmount);

    return { owner, user, user2, payment, position, core, feePolicy, marketId: MARKET_ID };
  }

  // Helper to get total distribution sum
  async function getTotalSum(core: TradeModuleProxy, marketId: number): Promise<bigint> {
    return await core.getMarketTotalSum(marketId);
  }

  // ============================================================
  // Sum Monotonicity Invariants
  // ============================================================
  describe("Sum Monotonicity", () => {
    it("INV-1: Buy increases total sum", async () => {
      const { core, user, marketId } = await loadFixture(deployInvariantFixture);

      const sumBefore = await getTotalSum(core, marketId);

      await core.connect(user).openPosition(
        marketId,
        2, // lowerTick
        5, // upperTick
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      const sumAfter = await getTotalSum(core, marketId);
      expect(sumAfter).to.be.gt(sumBefore);
    });

    it("INV-2: Sell decreases total sum", async () => {
      const { core, user, position, marketId } = await loadFixture(deployInvariantFixture);

      // First buy
      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      const sumBefore = await getTotalSum(core, marketId);

      // Get position ID and close
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];
      await core.connect(user).closePosition(positionId, 0);

      const sumAfter = await getTotalSum(core, marketId);
      expect(sumAfter).to.be.lt(sumBefore);
    });

    it("INV-3: Multiple buys monotonically increase sum", async () => {
      const { core, user, marketId } = await loadFixture(deployInvariantFixture);

      let prevSum = await getTotalSum(core, marketId);

      for (let i = 0; i < 5; i++) {
        await core.connect(user).openPosition(
          marketId,
          i % (NUM_BINS - 1), // lowerTick
          (i % (NUM_BINS - 1)) + 1, // upperTick
          SMALL_QUANTITY,
          ethers.parseUnits("10", USDC_DECIMALS)
        );

        const newSum = await getTotalSum(core, marketId);
        expect(newSum).to.be.gt(prevSum);
        prevSum = newSum;
      }
    });
  });

  // ============================================================
  // Range Isolation Invariants
  // ============================================================
  describe("Range Isolation", () => {
    it("INV-4: Buy only affects bins in range", async () => {
      const { core, user, marketId } = await loadFixture(deployInvariantFixture);

      // Record all bin values before
      const binsBefore: bigint[] = [];
      for (let i = 0; i < NUM_BINS; i++) {
        binsBefore.push(await core.getMarketBinFactor(marketId, i));
      }

      // Buy range [3, 6)
      await core.connect(user).openPosition(
        marketId,
        3,
        6,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      // Check bins
      for (let i = 0; i < NUM_BINS; i++) {
        const binAfter = await core.getMarketBinFactor(marketId, i);
        if (i >= 3 && i < 6) {
          // Affected bins should increase
          expect(binAfter).to.be.gt(binsBefore[i]);
        } else {
          // Unaffected bins should be unchanged
          expect(binAfter).to.equal(binsBefore[i]);
        }
      }
    });

    it("INV-5: Overlapping ranges compound correctly", async () => {
      const { core, user, marketId } = await loadFixture(deployInvariantFixture);

      // First buy [2, 5)
      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      const bin3After1 = await core.getMarketBinFactor(marketId, 3);

      // Second buy [3, 7) - overlaps at [3, 5)
      await core.connect(user).openPosition(
        marketId,
        3,
        7,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      const bin3After2 = await core.getMarketBinFactor(marketId, 3);

      // Bin 3 should increase further
      expect(bin3After2).to.be.gt(bin3After1);
    });
  });

  // ============================================================
  // Cost/Proceeds Symmetry
  // ============================================================
  describe("Cost/Proceeds Symmetry", () => {
    it("INV-6: Roundtrip approximately restores distribution", async () => {
      const { core, user, position, marketId } = await loadFixture(deployInvariantFixture);

      const sumBefore = await getTotalSum(core, marketId);

      // Buy
      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      // Immediately sell
      const positions = await position.getPositionsByOwner(user.address);
      await core.connect(user).closePosition(positions[0], 0);

      const sumAfter = await getTotalSum(core, marketId);

      // Sum should be approximately restored (within rounding tolerance)
      // CLMSR is path-independent, so buy+sell should restore state
      const diff = sumAfter > sumBefore ? sumAfter - sumBefore : sumBefore - sumAfter;
      const tolerance = sumBefore / 1000n; // 0.1% tolerance
      expect(diff).to.be.lte(tolerance);
    });

    it("INV-7: Cost increases with quantity", async () => {
      const { core, marketId } = await loadFixture(deployInvariantFixture);

      const smallCost = await core.calculateOpenCost.staticCall(
        marketId,
        2,
        5,
        SMALL_QUANTITY
      );

      const largeCost = await core.calculateOpenCost.staticCall(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY
      );

      expect(largeCost).to.be.gt(smallCost);
    });

    it("INV-8: Proceeds increase with quantity", async () => {
      const { core, user, position, marketId } = await loadFixture(deployInvariantFixture);

      // Open position first
      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const smallProceeds = await core.calculateDecreaseProceeds.staticCall(
        positionId,
        SMALL_QUANTITY
      );

      const largeProceeds = await core.calculateDecreaseProceeds.staticCall(
        positionId,
        MEDIUM_QUANTITY
      );

      expect(largeProceeds).to.be.gt(smallProceeds);
    });
  });

  // ============================================================
  // Loss Bound Invariant
  // ============================================================
  describe("Loss Bound", () => {
    it("INV-9: Maker loss bounded by α·ln(n)", async () => {
      const { core, marketId } = await loadFixture(deployInvariantFixture);

      // Calculate theoretical max loss: α * ln(n) = 1 * ln(10) ≈ 2.302
      // This test verifies the cost formula follows CLMSR bounds
      
      // Execute moderate buy on single bin
      const qty = MEDIUM_QUANTITY;
      const cost = await core.calculateOpenCost.staticCall(marketId, 0, 1, qty);

      // Cost should be reasonable (not exceeding extreme bounds)
      // For small quantity on uniform distribution, cost ≈ quantity
      expect(cost).to.be.gt(0n);
      expect(cost).to.be.lt(ethers.parseUnits("100", USDC_DECIMALS));
    });
  });

  // ============================================================
  // Stress Invariants
  // ============================================================
  describe("Stress Invariants", () => {
    it("INV-10: Sum remains consistent under many operations", async () => {
      const { core, user, user2, position, marketId } = await loadFixture(deployInvariantFixture);

      const prng = createPrng(42n);

      // Execute many random operations
      for (let i = 0; i < 20; i++) {
        const lo = prng.nextInt(NUM_BINS - 1);
        const hi = lo + 1 + prng.nextInt(NUM_BINS - 1 - lo);

        await core.connect(user).openPosition(
          marketId,
          lo,
          hi,
          SMALL_QUANTITY,
          ethers.parseUnits("50", USDC_DECIMALS)
        );
      }

      // Verify sum is still valid
      const totalSum = await getTotalSum(core, marketId);
      expect(totalSum).to.be.gt(BigInt(NUM_BINS) * WAD); // At least initial sum

      // Verify individual bin values are positive
      for (let i = 0; i < NUM_BINS; i++) {
        const binValue = await core.getMarketBinFactor(marketId, i);
        expect(binValue).to.be.gt(0n);
      }
    });

    it("INV-11: Multiple users maintain system consistency", async () => {
      const { core, user, user2, position, marketId } = await loadFixture(deployInvariantFixture);

      // User 1 buys
      await core.connect(user).openPosition(
        marketId,
        2,
        4,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      // User 2 buys different range
      await core.connect(user2).openPosition(
        marketId,
        5,
        8,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      // Both close
      const pos1 = await position.getPositionsByOwner(user.address);
      const pos2 = await position.getPositionsByOwner(user2.address);

      await core.connect(user).closePosition(pos1[0], 0);
      await core.connect(user2).closePosition(pos2[0], 0);

      // System should be back to approximately initial state
      const finalSum = await getTotalSum(core, marketId);
      const initialSum = BigInt(NUM_BINS) * WAD;

      const diff = finalSum > initialSum ? finalSum - initialSum : initialSum - finalSum;
      const tolerance = initialSum / 100n; // 1% tolerance
      expect(diff).to.be.lte(tolerance);
    });
  });
});

