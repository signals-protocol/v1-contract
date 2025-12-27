import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  SignalsPosition,
  SignalsCoreHarness,
  TradeModule,
  OracleModule,
  TestERC1967Proxy,
  LazyMulSegmentTree,
} from "../../../typechain-types";
import { WAD } from "../../helpers/constants";
import {
  DATA_FEED_ID,
  FEED_DECIMALS,
  authorisedWallets,
  buildRedstonePayload,
  submitWithPayload,
} from "../../helpers/redstone";

// Redstone feed config (for setRedstoneConfig)
const FEED_ID = ethers.encodeBytes32String(DATA_FEED_ID);
const MAX_SAMPLE_DISTANCE = 600n;
const FUTURE_TOLERANCE = 60n;

// Human price to tick mapping: humanPrice equals desired tick
function tickToHumanPrice(tick: bigint): number {
  return Number(tick);
}

async function deploySystem() {
  const [owner, u1, u2, u3] = await ethers.getSigners();

  const payment = await (
    await ethers.getContractFactory("SignalsUSDToken")
  ).deploy();
  await (await ethers.getContractFactory("MockFeePolicy")).deploy(0); // feePolicy not used directly

  const positionImplFactory = await ethers.getContractFactory(
    "SignalsPosition"
  );
  const positionImpl = await positionImplFactory.deploy();
  await positionImpl.waitForDeployment();
  const initData = positionImplFactory.interface.encodeFunctionData(
    "initialize",
    [owner.address]
  );
  const positionProxy = (await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(await positionImpl.getAddress(), initData)) as TestERC1967Proxy;
  const position = (await ethers.getContractAt(
    "SignalsPosition",
    await positionProxy.getAddress()
  )) as SignalsPosition;

  const lazy = (await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy()) as LazyMulSegmentTree;
  const tradeModule = (await (
    await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazy.target },
    })
  ).deploy()) as TradeModule;
  const lifecycleModule = (await (
    await ethers.getContractFactory("MarketLifecycleModule", {
      libraries: { LazyMulSegmentTree: lazy.target },
    })
  ).deploy()) as MarketLifecycleModule;
  // Use OracleModuleHarness to allow Hardhat local signers for Redstone verification
  const oracleModule = (await (
    await ethers.getContractFactory("OracleModuleHarness")
  ).deploy()) as OracleModule;
  const riskModule = await (
    await ethers.getContractFactory("RiskModule")
  ).deploy();
  const lpVaultModule = await (
    await ethers.getContractFactory("LPVaultModule")
  ).deploy();

  const coreImpl = (await (
    await ethers.getContractFactory("SignalsCoreHarness", {
      libraries: { LazyMulSegmentTree: lazy.target },
    })
  ).deploy()) as SignalsCoreHarness;
  const submitWindow = 200;
  const finalizeDeadline = 60;
  const initCore = coreImpl.interface.encodeFunctionData("initialize", [
    payment.target,
    await position.getAddress(),
    submitWindow,
    finalizeDeadline,
  ]);
  const coreProxy = (await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(coreImpl.target, initCore)) as TestERC1967Proxy;
  const core = (await ethers.getContractAt(
    "SignalsCoreHarness",
    await coreProxy.getAddress()
  )) as SignalsCoreHarness;

  await core.setModules(
    tradeModule.target,
    lifecycleModule.target,
    riskModule.target,
    lpVaultModule.target,
    oracleModule.target
  );
  
  // Configure Redstone oracle params
  await core.setRedstoneConfig(FEED_ID, FEED_DECIMALS, MAX_SAMPLE_DISTANCE, FUTURE_TOLERANCE);
  await position.connect(owner).setCore(await core.getAddress());

  // Configure risk and fee waterfall for vault
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
  await core.setMinSeedAmount(1_000_000n); // 1 USDC in 6 decimals

  // Seed vault with enough funds for payouts
  await payment.approve(await core.getAddress(), ethers.MaxUint256);
  await core.seedVault(100_000_000n); // 100 USDC

  // fund users and approve
  await payment.transfer(u1.address, 20_000_000n);
  await payment.transfer(u2.address, 20_000_000n);
  await payment.transfer(u3.address, 20_000_000n);
  for (const u of [u1, u2, u3]) {
    await payment
      .connect(u)
      .approve(await core.getAddress(), ethers.MaxUint256);
  }

  return {
    owner,
    u1,
    u2,
    u3,
    core,
    payment,
    position,
    lifecycleModule,
  };
}

describe("Settlement chunks and claim totals", () => {
  it("reverts requestSettlementChunks before market is settled", async () => {
    const { core, lifecycleModule } = await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0, 4, 1, Number(start), Number(end), Number(settleTs),
      4, WAD, ethers.ZeroAddress
    );

    // Market is active but not settled
    await expect(
      core.requestSettlementChunks(1, 10)
    ).to.be.revertedWithCustomError(lifecycleModule, "MarketNotSettled");
  });

  it("handles multiple users/positions across chunks and preserves payout totals", async () => {
    const { owner, u1, u2, u3, core, payment, lifecycleModule } =
      await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(settleTs),
      4,
      WAD,
      ethers.ZeroAddress
    );

    // open positions: 3 users, 4 positions -> ensure openPositionCount drives multiple chunks
    await core.connect(u1).openPosition(1, 0, 2, 1_000, 10_000_000); // winning
    await core.connect(u2).openPosition(1, 2, 4, 1_000, 10_000_000); // losing
    await core.connect(u3).openPosition(1, 1, 3, 1_000, 10_000_000); // winning
    await core.connect(u1).openPosition(1, 0, 1, 500, 10_000_000); // winning

    const openCount = (await core.markets(1)).openPositionCount;
    expect(openCount).to.equal(4);

    // settle with settlementTick = 1 (wins positions that include bin 1)
    // priceTimestamp must be >= Tset (settlementTimestamp)
    const priceTimestamp = settleTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const payload = buildRedstonePayload(tickToHumanPrice(1n), Number(priceTimestamp), authorisedWallets);
    await submitWithPayload(core, owner, 1, payload);
    // finalize after PendingOps ends (submitWindow=200, pendingOpsWindow=60)
    const opsEnd = settleTs + 200n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await core.finalizePrimarySettlement(1);

    // chunk emission: with 4 positions totalChunks=1, ensure snapshot completes and further calls revert
    const tx1 = await core.requestSettlementChunks(1, 10);
    await expect(tx1)
      .to.emit(
        lifecycleModule.attach(await core.getAddress()),
        "SettlementChunkRequested"
      )
      .withArgs(1, 0);
    await expect(
      core.requestSettlementChunks(1, 10)
    ).to.be.revertedWithCustomError(
      lifecycleModule,
      "SnapshotAlreadyCompleted"
    );

    // wait claim gate
    await time.increase(61);

    // top up core to ensure payouts (simulating fee pool)
    const coreAddr = await core.getAddress();
    await payment.transfer(coreAddr, 10_000_000n);

    const balBefore =
      (await payment.balanceOf(u1.address)) +
      (await payment.balanceOf(u2.address)) +
      (await payment.balanceOf(u3.address));

    const ids = [1, 2, 3, 4];
    await core.connect(u1).claimPayout(ids[0]);
    await core.connect(u2).claimPayout(ids[1]);
    await core.connect(u3).claimPayout(ids[2]);
    await core.connect(u1).claimPayout(ids[3]);

    const balAfter =
      (await payment.balanceOf(u1.address)) +
      (await payment.balanceOf(u2.address)) +
      (await payment.balanceOf(u3.address));
    // settlementTick=1 -> winners: [0,2], [1,3]; [0,1] loses because upperTick == settlementTick
    // Position 1: [0,2) contains 1 → WIN (1000)
    // Position 2: [2,4) doesn't contain 1 → LOSE (0)
    // Position 3: [1,3) contains 1 → WIN (1000)
    // Position 4: [0,1) doesn't contain 1 (upperTick exclusive) → LOSE (0)
    expect(balAfter - balBefore).to.equal(1_000 + 1_000);
  });

  it("completes snapshot in single chunk when positions < CHUNK_SIZE", async () => {
    // CHUNK_SIZE = 512 in MarketLifecycleModule
    // With 4 positions, only 1 chunk is needed (4 < 512)
    const { owner, u1, u2, u3, core, lifecycleModule } = await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0, 4, 1, Number(start), Number(end), Number(settleTs),
      4, WAD, ethers.ZeroAddress
    );

    // Create 4 positions (less than CHUNK_SIZE=512)
    await core.connect(u1).openPosition(1, 0, 2, 1_000, 10_000_000);
    await core.connect(u2).openPosition(1, 0, 2, 1_000, 10_000_000);
    await core.connect(u3).openPosition(1, 0, 2, 1_000, 10_000_000);
    await core.connect(u1).openPosition(1, 0, 2, 1_000, 10_000_000);

    const openCount = (await core.markets(1)).openPositionCount;
    expect(openCount).to.equal(4);

    // Settle market
    const priceTimestamp = settleTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const payload = buildRedstonePayload(tickToHumanPrice(1n), Number(priceTimestamp), authorisedWallets);
    await submitWithPayload(core, owner, 1, payload);
    const opsEnd = settleTs + 200n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await core.finalizePrimarySettlement(1);

    // Single chunk request should emit event and complete snapshot
    const tx1 = await core.requestSettlementChunks(1, 10);
    await expect(tx1).to.emit(
      lifecycleModule.attach(await core.getAddress()),
      "SettlementChunkRequested"
    ).withArgs(1, 0);

    // Verify snapshot is complete - second call should revert
    await expect(core.requestSettlementChunks(1, 10))
      .to.be.revertedWithCustomError(lifecycleModule, "SnapshotAlreadyCompleted");
  });

  it("reverts claim on non-winning position (payout = 0)", async () => {
    const { owner, u1, core, payment } = await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0, 4, 1, Number(start), Number(end), Number(settleTs),
      4, WAD, ethers.ZeroAddress
    );

    // Position 1: [2,4) - will lose when settlementTick = 1
    await core.connect(u1).openPosition(1, 2, 4, 1_000, 10_000_000);

    // Settle with tick = 1
    const priceTimestamp = settleTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const payload = buildRedstonePayload(tickToHumanPrice(1n), Number(priceTimestamp), authorisedWallets);
    await submitWithPayload(core, owner, 1, payload);
    const opsEnd = settleTs + 200n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await core.finalizePrimarySettlement(1);

    await core.requestSettlementChunks(1, 10);
    await time.increase(61);

    const balBefore = await payment.balanceOf(u1.address);
    await core.connect(u1).claimPayout(1);
    const balAfter = await payment.balanceOf(u1.address);

    // Losing position should have 0 payout
    expect(balAfter - balBefore).to.equal(0n);
  });

  it("boundary: settlementTick equals upperTick - 1 (winning)", async () => {
    const { owner, u1, core, payment } = await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0, 4, 1, Number(start), Number(end), Number(settleTs),
      4, WAD, ethers.ZeroAddress
    );

    // Position [1,3) - winning if settlementTick = 2 (upper - 1)
    await core.connect(u1).openPosition(1, 1, 3, 1_000, 10_000_000);

    // Settle with tick = 2
    const priceTimestamp = settleTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const payload = buildRedstonePayload(tickToHumanPrice(2n), Number(priceTimestamp), authorisedWallets);
    await submitWithPayload(core, owner, 1, payload);
    const opsEnd = settleTs + 200n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await core.finalizePrimarySettlement(1);

    await core.requestSettlementChunks(1, 10);
    await time.increase(61);

    const balBefore = await payment.balanceOf(u1.address);
    await core.connect(u1).claimPayout(1);
    const balAfter = await payment.balanceOf(u1.address);

    // Should win: lowerTick(1) <= settlementTick(2) < upperTick(3)
    expect(balAfter - balBefore).to.equal(1_000n);
  });

  it("boundary: settlementTick equals lowerTick (winning)", async () => {
    const { owner, u1, core, payment } = await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0, 4, 1, Number(start), Number(end), Number(settleTs),
      4, WAD, ethers.ZeroAddress
    );

    // Position [2,4) - winning if settlementTick = 2 (equals lowerTick)
    await core.connect(u1).openPosition(1, 2, 4, 1_000, 10_000_000);

    // Settle with tick = 2
    const priceTimestamp = settleTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const payload = buildRedstonePayload(tickToHumanPrice(2n), Number(priceTimestamp), authorisedWallets);
    await submitWithPayload(core, owner, 1, payload);
    const opsEnd = settleTs + 200n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await core.finalizePrimarySettlement(1);

    await core.requestSettlementChunks(1, 10);
    await time.increase(61);

    const balBefore = await payment.balanceOf(u1.address);
    await core.connect(u1).claimPayout(1);
    const balAfter = await payment.balanceOf(u1.address);

    // Should win: lowerTick(2) <= settlementTick(2) < upperTick(4)
    expect(balAfter - balBefore).to.equal(1_000n);
  });

  it("boundary: settlementTick equals upperTick (losing)", async () => {
    const { owner, u1, core, payment } = await deploySystem();

    const now = BigInt(await time.latest());
    const start = now - 10n;
    const end = now + 100n;
    const settleTs = end + 10n;
    await core.createMarketUniform(
      0, 4, 1, Number(start), Number(end), Number(settleTs),
      4, WAD, ethers.ZeroAddress
    );

    // Position [0,2) - losing if settlementTick = 2 (equals upperTick)
    await core.connect(u1).openPosition(1, 0, 2, 1_000, 10_000_000);

    // Settle with tick = 2
    const priceTimestamp = settleTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const payload = buildRedstonePayload(tickToHumanPrice(2n), Number(priceTimestamp), authorisedWallets);
    await submitWithPayload(core, owner, 1, payload);
    const opsEnd = settleTs + 200n + 60n;
    await time.setNextBlockTimestamp(Number(opsEnd + 1n));
    await core.finalizePrimarySettlement(1);

    await core.requestSettlementChunks(1, 10);
    await time.increase(61);

    const balBefore = await payment.balanceOf(u1.address);
    await core.connect(u1).claimPayout(1);
    const balAfter = await payment.balanceOf(u1.address);

    // Should lose: lowerTick(0) <= settlementTick(2) but 2 < upperTick(2) is FALSE
    expect(balAfter - balBefore).to.equal(0n);
  });
});
