import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MockPaymentToken,
  MockFeePolicy,
  TradeModuleProxy,
  TradeModule,
  SignalsPosition,
} from "../../../typechain-types";
import { ISignalsCore } from "../../../typechain-types/contracts/testonly/TradeModuleProxy";
import { WAD, USDC_DECIMALS, SMALL_QUANTITY, MEDIUM_QUANTITY } from "../../helpers/constants";
import { LogDescription, ContractTransactionReceipt } from "ethers";

/**
 * v0-style Position Events Test Suite
 * 
 * Tests for v0 parity: correct event emission with proper order and parameters.
 * 
 * v0 style event order (MUST be preserved):
 * - open:     PositionOpened   → (fee>0) TradeFeeCharged
 * - increase: PositionIncreased → (fee>0) TradeFeeCharged
 * - decrease: PositionDecreased → (fee>0) TradeFeeCharged
 * - close:    PositionClosed    → (fee>0) TradeFeeCharged
 * 
 * Key invariants:
 * 1. Position event MUST emit before TradeFeeCharged
 * 2. TradeFeeCharged.baseAmount == cost/proceeds from Position event
 * 3. TradeFeeCharged only emits when fee > 0
 */

interface DeployedSystem {
  owner: HardhatEthersSigner;
  user: HardhatEthersSigner;
  payment: MockPaymentToken;
  position: SignalsPosition;
  core: TradeModuleProxy;
  feePolicy: MockFeePolicy;
  tradeModule: TradeModule;
  marketId: number;
}

describe("v0-style Position Events (TradeModule)", () => {
  const NUM_BINS = 10;
  const MARKET_ID = 1;

  async function deployFixtureWithFee(feeBps = 0): Promise<DeployedSystem> {
    const [owner, user] = await ethers.getSigners();

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
    ).deploy(feeBps);

    const lazyLib = await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy();
    const tradeModuleImpl = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();

    const core = await (
      await ethers.getContractFactory("TradeModuleProxy", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy(tradeModuleImpl.target);

    const tradeModule = await ethers.getContractAt("TradeModule", core.target) as unknown as TradeModule;

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
      failed: false,
      numBins: NUM_BINS,
      openPositionCount: 0,
      snapshotChunkCursor: 0,
      startTimestamp: now - 100,
      endTimestamp: now + 100000,
      settlementTimestamp: now + 100100,
      settlementFinalizedAt: 0,
      minTick: 0,
      maxTick: NUM_BINS,
      tickSpacing: 1,
      settlementTick: 0,
      settlementValue: 0,
      liquidityParameter: WAD,
      feePolicy: feeBps > 0 ? await feePolicy.getAddress() : ethers.ZeroAddress,
      initialRootSum: BigInt(NUM_BINS) * WAD,
      accumulatedFees: 0n,
      minFactor: WAD,
      deltaEt: 0n,
    };
    await core.setMarket(MARKET_ID, market);

    const factors = Array(NUM_BINS).fill(WAD);
    await core.seedTree(MARKET_ID, factors);

    await position.connect(owner).setCore(core.target);

    const fundAmount = ethers.parseUnits("100000", USDC_DECIMALS);
    await payment.transfer(user.address, fundAmount);
    await payment.connect(user).approve(core.target, fundAmount);

    return { owner, user, payment, position, core, feePolicy, tradeModule, marketId: MARKET_ID };
  }

  async function deployNoFeeFixture(): Promise<DeployedSystem> {
    return deployFixtureWithFee(0);
  }

  async function deployWithFeeFixture(): Promise<DeployedSystem> {
    return deployFixtureWithFee(100); // 1% fee
  }

  /**
   * Helper to parse events from a transaction receipt
   */
  function parseEvents(
    receipt: ContractTransactionReceipt | null,
    iface: TradeModule["interface"]
  ): LogDescription[] {
    if (!receipt || !receipt.logs) return [];
    return receipt.logs
      .map((log) => {
        try {
          return iface.parseLog({ topics: log.topics as string[], data: log.data });
        } catch {
          return null;
        }
      })
      .filter((e): e is LogDescription => e !== null);
  }

  /**
   * Find events by name from parsed events
   */
  function findEventsByName(events: LogDescription[], name: string): LogDescription[] {
    return events.filter((e) => e.name === name);
  }

  /**
   * Get index of first event by name
   */
  function getEventIndex(events: LogDescription[], name: string): number {
    return events.findIndex((e) => e.name === name);
  }

  // ============================================================
  // A1) PositionOpened Event Tests
  // ============================================================
  describe("PositionOpened Event", () => {
    it("emits PositionOpened with correct parameters on openPosition", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      const nextId = await position.nextId();
      const lowerTick = 2;
      const upperTick = 5;
      const quantity = MEDIUM_QUANTITY;

      const tx = await core.connect(user).openPosition(
        marketId,
        lowerTick,
        upperTick,
        quantity,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      // Must emit PositionOpened
      const positionOpenedEvents = findEventsByName(events, "PositionOpened");
      expect(positionOpenedEvents.length).to.equal(1, "Should emit exactly one PositionOpened event");

      const evt = positionOpenedEvents[0];
      expect(evt.args.positionId).to.equal(nextId);
      expect(evt.args.trader).to.equal(user.address);
      expect(evt.args.marketId).to.equal(marketId);
      expect(evt.args.lowerTick).to.equal(lowerTick);
      expect(evt.args.upperTick).to.equal(upperTick);
      expect(evt.args.quantity).to.equal(quantity);
      expect(evt.args.cost).to.be.gt(0);
    });

    it("emits PositionOpened before TradeFeeCharged when fee > 0", async () => {
      const { core, user, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posOpenedIdx = getEventIndex(events, "PositionOpened");
      const feeIdx = getEventIndex(events, "TradeFeeCharged");

      expect(posOpenedIdx).to.be.gte(0, "PositionOpened must be emitted");
      expect(feeIdx).to.be.gte(0, "TradeFeeCharged must be emitted when fee > 0");
      expect(posOpenedIdx).to.be.lt(feeIdx, "PositionOpened must come BEFORE TradeFeeCharged");
    });

    it("TradeFeeCharged.baseAmount matches PositionOpened.cost", async () => {
      const { core, user, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posOpened = findEventsByName(events, "PositionOpened")[0];
      const feeCharged = findEventsByName(events, "TradeFeeCharged")[0];

      expect(posOpened).to.not.be.undefined;
      expect(feeCharged).to.not.be.undefined;
      expect(feeCharged.args.baseAmount).to.equal(posOpened.args.cost, 
        "TradeFeeCharged.baseAmount must equal PositionOpened.cost");
      expect(feeCharged.args.isBuy).to.equal(true, "isBuy should be true for open");
    });
  });

  // ============================================================
  // A2) PositionIncreased Event Tests
  // ============================================================
  describe("PositionIncreased Event", () => {
    it("emits PositionIncreased with correct parameters on increasePosition", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      // First open a position
      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );

      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];
      const posBefore = await position.getPosition(positionId);
      const deltaQuantity = SMALL_QUANTITY;

      const tx = await core.connect(user).increasePosition(
        positionId,
        deltaQuantity,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      // Must emit PositionIncreased
      const posIncreasedEvents = findEventsByName(events, "PositionIncreased");
      expect(posIncreasedEvents.length).to.equal(1, "Should emit exactly one PositionIncreased event");

      const evt = posIncreasedEvents[0];
      expect(evt.args.positionId).to.equal(positionId);
      expect(evt.args.trader).to.equal(user.address);
      expect(evt.args.deltaQuantity).to.equal(deltaQuantity);
      expect(evt.args.newQuantity).to.equal(posBefore.quantity + BigInt(deltaQuantity));
      expect(evt.args.cost).to.be.gt(0);
    });

    it("emits PositionIncreased before TradeFeeCharged when fee > 0", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).increasePosition(
        positionId,
        SMALL_QUANTITY,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posIncreasedIdx = getEventIndex(events, "PositionIncreased");
      const feeIdx = getEventIndex(events, "TradeFeeCharged");

      expect(posIncreasedIdx).to.be.gte(0, "PositionIncreased must be emitted");
      expect(feeIdx).to.be.gte(0, "TradeFeeCharged must be emitted when fee > 0");
      expect(posIncreasedIdx).to.be.lt(feeIdx, "PositionIncreased must come BEFORE TradeFeeCharged");
    });

    it("TradeFeeCharged.baseAmount matches PositionIncreased.cost", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).increasePosition(
        positionId,
        SMALL_QUANTITY,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posIncreased = findEventsByName(events, "PositionIncreased")[0];
      const feeCharged = findEventsByName(events, "TradeFeeCharged")[0];

      expect(posIncreased).to.not.be.undefined;
      expect(feeCharged).to.not.be.undefined;
      expect(feeCharged.args.baseAmount).to.equal(posIncreased.args.cost,
        "TradeFeeCharged.baseAmount must equal PositionIncreased.cost");
      expect(feeCharged.args.isBuy).to.equal(true, "isBuy should be true for increase");
    });
  });

  // ============================================================
  // A3) PositionDecreased Event Tests
  // ============================================================
  describe("PositionDecreased Event", () => {
    it("emits PositionDecreased with correct parameters on decreasePosition", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];
      const posBefore = await position.getPosition(positionId);
      const deltaQuantity = SMALL_QUANTITY;

      const tx = await core.connect(user).decreasePosition(
        positionId,
        deltaQuantity,
        0
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      // Must emit PositionDecreased
      const posDecreasedEvents = findEventsByName(events, "PositionDecreased");
      expect(posDecreasedEvents.length).to.equal(1, "Should emit exactly one PositionDecreased event");

      const evt = posDecreasedEvents[0];
      expect(evt.args.positionId).to.equal(positionId);
      expect(evt.args.trader).to.equal(user.address);
      expect(evt.args.deltaQuantity).to.equal(deltaQuantity);
      expect(evt.args.newQuantity).to.equal(posBefore.quantity - BigInt(deltaQuantity));
      expect(evt.args.proceeds).to.be.gt(0);
    });

    it("emits PositionDecreased before TradeFeeCharged when fee > 0", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).decreasePosition(
        positionId,
        SMALL_QUANTITY,
        0
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posDecreasedIdx = getEventIndex(events, "PositionDecreased");
      const feeIdx = getEventIndex(events, "TradeFeeCharged");

      expect(posDecreasedIdx).to.be.gte(0, "PositionDecreased must be emitted");
      expect(feeIdx).to.be.gte(0, "TradeFeeCharged must be emitted when fee > 0");
      expect(posDecreasedIdx).to.be.lt(feeIdx, "PositionDecreased must come BEFORE TradeFeeCharged");
    });

    it("TradeFeeCharged.baseAmount matches PositionDecreased.proceeds", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).decreasePosition(
        positionId,
        SMALL_QUANTITY,
        0
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posDecreased = findEventsByName(events, "PositionDecreased")[0];
      const feeCharged = findEventsByName(events, "TradeFeeCharged")[0];

      expect(posDecreased).to.not.be.undefined;
      expect(feeCharged).to.not.be.undefined;
      expect(feeCharged.args.baseAmount).to.equal(posDecreased.args.proceeds,
        "TradeFeeCharged.baseAmount must equal PositionDecreased.proceeds");
      expect(feeCharged.args.isBuy).to.equal(false, "isBuy should be false for decrease");
    });
  });

  // ============================================================
  // A4) PositionClosed Event Tests
  // ============================================================
  describe("PositionClosed Event", () => {
    it("emits PositionClosed with correct parameters on closePosition", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).closePosition(positionId, 0);
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      // Must emit PositionClosed
      const posClosedEvents = findEventsByName(events, "PositionClosed");
      expect(posClosedEvents.length).to.equal(1, "Should emit exactly one PositionClosed event");

      const evt = posClosedEvents[0];
      expect(evt.args.positionId).to.equal(positionId);
      expect(evt.args.trader).to.equal(user.address);
      expect(evt.args.proceeds).to.be.gt(0);
    });

    it("emits PositionClosed before TradeFeeCharged when fee > 0", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).closePosition(positionId, 0);
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posClosedIdx = getEventIndex(events, "PositionClosed");
      const feeIdx = getEventIndex(events, "TradeFeeCharged");

      expect(posClosedIdx).to.be.gte(0, "PositionClosed must be emitted");
      expect(feeIdx).to.be.gte(0, "TradeFeeCharged must be emitted when fee > 0");
      expect(posClosedIdx).to.be.lt(feeIdx, "PositionClosed must come BEFORE TradeFeeCharged");
    });

    it("TradeFeeCharged.baseAmount matches PositionClosed.proceeds", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).closePosition(positionId, 0);
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posClosed = findEventsByName(events, "PositionClosed")[0];
      const feeCharged = findEventsByName(events, "TradeFeeCharged")[0];

      expect(posClosed).to.not.be.undefined;
      expect(feeCharged).to.not.be.undefined;
      expect(feeCharged.args.baseAmount).to.equal(posClosed.args.proceeds,
        "TradeFeeCharged.baseAmount must equal PositionClosed.proceeds");
      expect(feeCharged.args.isBuy).to.equal(false, "isBuy should be false for close");
    });

    it("does NOT emit PositionDecreased on closePosition (only PositionClosed)", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).closePosition(positionId, 0);
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const posDecreased = findEventsByName(events, "PositionDecreased");
      const posClosed = findEventsByName(events, "PositionClosed");

      expect(posDecreased.length).to.equal(0, "PositionDecreased should NOT be emitted on close");
      expect(posClosed.length).to.equal(1, "PositionClosed MUST be emitted on close");
    });
  });

  // ============================================================
  // A5) TradeFeeCharged Conditional Emission Tests
  // ============================================================
  describe("TradeFeeCharged Conditional Emission", () => {
    it("does NOT emit TradeFeeCharged when fee = 0 (open)", async () => {
      const { core, user, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvents = findEventsByName(events, "TradeFeeCharged");
      expect(feeEvents.length).to.equal(0, "TradeFeeCharged should NOT be emitted when fee = 0");
    });

    it("does NOT emit TradeFeeCharged when fee = 0 (increase)", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).increasePosition(
        positionId,
        SMALL_QUANTITY,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvents = findEventsByName(events, "TradeFeeCharged");
      expect(feeEvents.length).to.equal(0, "TradeFeeCharged should NOT be emitted when fee = 0");
    });

    it("does NOT emit TradeFeeCharged when fee = 0 (decrease)", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).decreasePosition(
        positionId,
        SMALL_QUANTITY,
        0
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvents = findEventsByName(events, "TradeFeeCharged");
      expect(feeEvents.length).to.equal(0, "TradeFeeCharged should NOT be emitted when fee = 0");
    });

    it("does NOT emit TradeFeeCharged when fee = 0 (close)", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      const tx = await core.connect(user).closePosition(positionId, 0);
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvents = findEventsByName(events, "TradeFeeCharged");
      expect(feeEvents.length).to.equal(0, "TradeFeeCharged should NOT be emitted when fee = 0");
    });

    it("DOES emit TradeFeeCharged when fee > 0", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      // Open
      const openTx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const openReceipt = await openTx.wait();
      const openEvents = parseEvents(openReceipt, tradeModule.interface);
      expect(findEventsByName(openEvents, "TradeFeeCharged").length).to.equal(1);

      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      // Increase
      const incTx = await core.connect(user).increasePosition(
        positionId,
        SMALL_QUANTITY,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      const incReceipt = await incTx.wait();
      const incEvents = parseEvents(incReceipt, tradeModule.interface);
      expect(findEventsByName(incEvents, "TradeFeeCharged").length).to.equal(1);

      // Decrease
      const decTx = await core.connect(user).decreasePosition(
        positionId,
        SMALL_QUANTITY,
        0
      );
      const decReceipt = await decTx.wait();
      const decEvents = parseEvents(decReceipt, tradeModule.interface);
      expect(findEventsByName(decEvents, "TradeFeeCharged").length).to.equal(1);

      // Close
      const closeTx = await core.connect(user).closePosition(positionId, 0);
      const closeReceipt = await closeTx.wait();
      const closeEvents = parseEvents(closeReceipt, tradeModule.interface);
      expect(findEventsByName(closeEvents, "TradeFeeCharged").length).to.equal(1);
    });
  });

  // ============================================================
  // A6) TradeFeeCharged Parameters Validation
  // ============================================================
  describe("TradeFeeCharged Parameters", () => {
    it("emits correct feePolicy address", async () => {
      const { core, user, feePolicy, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvent = findEventsByName(events, "TradeFeeCharged")[0];
      expect(feeEvent.args.policy).to.equal(await feePolicy.getAddress());
    });

    it("emits correct positionId in TradeFeeCharged", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      const nextId = await position.nextId();
      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvent = findEventsByName(events, "TradeFeeCharged")[0];
      expect(feeEvent.args.positionId).to.equal(nextId);
    });

    it("emits correct marketId in TradeFeeCharged", async () => {
      const { core, user, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvent = findEventsByName(events, "TradeFeeCharged")[0];
      expect(feeEvent.args.marketId).to.equal(marketId);
    });

    it("emits correct trader address in TradeFeeCharged", async () => {
      const { core, user, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      const tx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      const receipt = await tx.wait();
      const events = parseEvents(receipt, tradeModule.interface);

      const feeEvent = findEventsByName(events, "TradeFeeCharged")[0];
      expect(feeEvent.args.trader).to.equal(user.address);
    });
  });

  // ============================================================
  // A7) Full Trade Lifecycle Event Sequence
  // ============================================================
  describe("Full Trade Lifecycle Event Sequence", () => {
    it("complete lifecycle emits events in correct order (with fee)", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployWithFeeFixture);

      // 1. Open
      const openTx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      let receipt = await openTx.wait();
      let events = parseEvents(receipt, tradeModule.interface);
      
      expect(getEventIndex(events, "PositionOpened")).to.be.gte(0);
      expect(getEventIndex(events, "PositionOpened")).to.be.lt(getEventIndex(events, "TradeFeeCharged"));

      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      // 2. Increase
      const incTx = await core.connect(user).increasePosition(
        positionId,
        SMALL_QUANTITY,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      receipt = await incTx.wait();
      events = parseEvents(receipt, tradeModule.interface);
      
      expect(getEventIndex(events, "PositionIncreased")).to.be.gte(0);
      expect(getEventIndex(events, "PositionIncreased")).to.be.lt(getEventIndex(events, "TradeFeeCharged"));

      // 3. Decrease
      const decTx = await core.connect(user).decreasePosition(
        positionId,
        SMALL_QUANTITY,
        0
      );
      receipt = await decTx.wait();
      events = parseEvents(receipt, tradeModule.interface);
      
      expect(getEventIndex(events, "PositionDecreased")).to.be.gte(0);
      expect(getEventIndex(events, "PositionDecreased")).to.be.lt(getEventIndex(events, "TradeFeeCharged"));

      // 4. Close
      const closeTx = await core.connect(user).closePosition(positionId, 0);
      receipt = await closeTx.wait();
      events = parseEvents(receipt, tradeModule.interface);
      
      expect(getEventIndex(events, "PositionClosed")).to.be.gte(0);
      expect(getEventIndex(events, "PositionClosed")).to.be.lt(getEventIndex(events, "TradeFeeCharged"));
    });

    it("complete lifecycle emits only position events (without fee)", async () => {
      const { core, user, position, tradeModule, marketId } = await loadFixture(deployNoFeeFixture);

      // 1. Open
      const openTx = await core.connect(user).openPosition(
        marketId,
        2,
        5,
        MEDIUM_QUANTITY,
        ethers.parseUnits("100", USDC_DECIMALS)
      );
      let receipt = await openTx.wait();
      let events = parseEvents(receipt, tradeModule.interface);
      
      expect(findEventsByName(events, "PositionOpened").length).to.equal(1);
      expect(findEventsByName(events, "TradeFeeCharged").length).to.equal(0);

      const positions = await position.getPositionsByOwner(user.address);
      const positionId = positions[0];

      // 2. Increase
      const incTx = await core.connect(user).increasePosition(
        positionId,
        SMALL_QUANTITY,
        ethers.parseUnits("50", USDC_DECIMALS)
      );
      receipt = await incTx.wait();
      events = parseEvents(receipt, tradeModule.interface);
      
      expect(findEventsByName(events, "PositionIncreased").length).to.equal(1);
      expect(findEventsByName(events, "TradeFeeCharged").length).to.equal(0);

      // 3. Decrease
      const decTx = await core.connect(user).decreasePosition(
        positionId,
        SMALL_QUANTITY,
        0
      );
      receipt = await decTx.wait();
      events = parseEvents(receipt, tradeModule.interface);
      
      expect(findEventsByName(events, "PositionDecreased").length).to.equal(1);
      expect(findEventsByName(events, "TradeFeeCharged").length).to.equal(0);

      // 4. Close
      const closeTx = await core.connect(user).closePosition(positionId, 0);
      receipt = await closeTx.wait();
      events = parseEvents(receipt, tradeModule.interface);
      
      expect(findEventsByName(events, "PositionClosed").length).to.equal(1);
      expect(findEventsByName(events, "TradeFeeCharged").length).to.equal(0);
    });
  });
});
