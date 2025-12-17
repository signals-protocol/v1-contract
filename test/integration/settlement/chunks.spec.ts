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
    await ethers.getContractFactory("MockPaymentToken")
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
  // Use OracleModuleTest to allow Hardhat local signers for Redstone verification
  const oracleModule = (await (
    await ethers.getContractFactory("OracleModuleTest")
  ).deploy()) as OracleModule;
  const riskModule = await (
    await ethers.getContractFactory("RiskModule")
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
    ethers.ZeroAddress,
    oracleModule.target
  );
  
  // Configure Redstone oracle params
  await core.setRedstoneConfig(FEED_ID, FEED_DECIMALS, MAX_SAMPLE_DISTANCE, FUTURE_TOLERANCE);
  await position.connect(owner).setCore(await core.getAddress());

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
    expect(balAfter - balBefore).to.equal(1_000 + 1_000);
  });
});
